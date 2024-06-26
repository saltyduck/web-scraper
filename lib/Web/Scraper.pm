package Web::Scraper;
use strict;
use warnings;
use 5.008001;
use Carp;
use Scalar::Util qw(blessed);
use List::Util qw(first);
use HTML::Entities;
use HTML::Tagset;
use HTML::TreeBuilder::XPath;
use HTML::Selector::XPath;
use UNIVERSAL::require;

our $VERSION = '0.38';

sub import {
    my $class = shift;
    my $pkg   = caller;

    no strict 'refs';
    no warnings 'redefine';
    *{"$pkg\::scraper"}       = _build_scraper($class);
    *{"$pkg\::process"}       = sub { goto &process };
    *{"$pkg\::process_first"} = sub { goto &process_first };
    *{"$pkg\::result"}        = sub { goto &result  };
}

our $UserAgent;

sub __ua {
    require LWP::UserAgent;
    $UserAgent ||= LWP::UserAgent->new(agent => __PACKAGE__ . "/" . $VERSION);
    $UserAgent;
}

sub user_agent {
    my $self = shift;
    $self->{user_agent} = shift if @_;
    $self->{user_agent} || __ua;
}

sub define {
    my($class, $coderef) = @_;
    bless { code => $coderef }, $class;
}

sub _build_scraper {
    my $class = shift;
    return sub(&) {
        my($coderef) = @_;
        bless { code => $coderef }, $class;
    };
}

sub scrape {
    my $self  = shift;
    my($stuff, $current_or_tree_attrs) = @_;

    my $current;
    my $treebuilder_attrs = {};
    if (ref $current_or_tree_attrs eq 'HASH') {
        $current = $current_or_tree_attrs->{base_url};
        my %opt = %$current_or_tree_attrs;
        undef $opt{base_url};
        $treebuilder_attrs = { ignore_unknown=>0, %opt };
    } else {
        # is a string;
        $current = $current_or_tree_attrs;
    }

    my($html, $tree);

    if (blessed($stuff) && $stuff->isa('URI')) {
        my $ua  = $self->user_agent;
        my $res = $ua->get($stuff);
        return $self->scrape($res, $stuff->as_string);
    } elsif (blessed($stuff) && $stuff->isa('HTTP::Response')) {
        if ($stuff->is_success) {
            $html = $stuff->decoded_content;
        } else {
            croak "GET " . $stuff->request->uri . " failed: ", $stuff->status_line;
        }
        $current ||= $stuff->request->uri;
    } elsif (blessed($stuff) && $stuff->isa('HTML::Element')) {
        $tree = $stuff->clone;
    } elsif (ref($stuff) && ref($stuff) eq 'SCALAR') {
        $html = $$stuff;
    } else {
        $html = $stuff;
    }

    $tree ||= $self->build_tree($html, $treebuilder_attrs);

    my $stash = {};
    no warnings 'redefine';
    local *process       = create_process(0, $tree, $stash, $current);
    local *process_first = create_process(1, $tree, $stash, $current);

    my $retval;
    local *result = sub {
        $retval++;
        my @keys = @_;

        if (@keys == 1) {
            return $stash->{$keys[0]};
        } elsif (@keys) {
            my %res;
            @res{@keys} = @{$stash}{@keys};
            return \%res;
        } else {
            return $stash;
        }
    };

    my $ret = $self->{code}->($tree);
    $tree->delete;

    # check user specified return value
    return $ret if $retval;

    return $stash;
}

sub _set_attributes {
    my ($t, $attrs) = @_;
    while (my($name, $val) = each %$attrs) {
        next unless $t->can($name);
        no strict 'refs';
        $t->$name($val);
    }
}

sub build_tree {
    my($self, $html, $tree_attrs) = @_;

    my $t = HTML::TreeBuilder::XPath->new;
    $t->store_comments(1) if ($t->can('store_comments'));
    $t->ignore_unknown(0);
    _set_attributes($t, $tree_attrs);
    $t->parse($html);
    $t->eof;
    $t;
}

sub create_process {
    my($first, $tree, $stash, $uri) = @_;

    sub {
        my($exp, @attr) = @_;

        my $xpath = $exp =~ m!^(?:/|id\()! ? $exp : HTML::Selector::XPath::selector_to_xpath($exp);
        my @nodes = eval {
            local $SIG{__WARN__} = sub { };
            $tree->findnodes($xpath);
        };

        if ($@) {
            die "'$xpath' doesn't look like a valid XPath expression: $@";
        }

        @nodes or return;
        @nodes = ($nodes[0]) if $first;

        while (my($key, $val) = splice(@attr, 0, 2)) {
            if (!defined $val) {
                if (ref($key) && ref($key) eq 'CODE') {
                    for my $node (@nodes) {
                        local $_ = $node;
                        $key->($node);
                    }
                } else {
                    die "Don't know what to do with $key => undef";
                }
            } elsif ($key =~ s!\[\]$!!) {
                $stash->{$key} = [ map __get_value($_, $val, $uri), @nodes ];
            } else {
                $stash->{$key} = __get_value($nodes[0], $val, $uri);
            }
        }

        return;
    };
}

sub __get_value {
    my($node, $val, $uri) = @_;

    if (ref($val) && ref($val) eq 'CODE') {
        local $_ = $node;
        return $val->($node);
    } elsif (blessed($val) && $val->isa('Web::Scraper')) {
        return $val->scrape($node, $uri);
    } elsif ($val =~ s!^@!!) {
        my $value =  $node->attr($val);
        if ($uri && is_link_element($node, $val)) {
            require URI;
            $value = URI->new_abs($value, $uri);
        }
        return $value;
    } elsif (lc($val) eq 'content' || lc($val) eq 'text') {
        # getValue method is used for getting a content of comment nodes
        # from HTML::TreeBuilder::XPath (version >= 0.14)
        # or HTML::TreeBuilder::LibXML (version >= 0.13)
        # getValue method works like as_text in both modules
        # for other node types
        return $node->isTextNode
            ? $node->string_value
            : ($node->can('getValue')
                ? $node->getValue
                : $node->as_text);
    } elsif (lc($val) eq 'raw' || lc($val) eq 'html') {
        if ($node->isTextNode) {
            if ($HTML::TreeBuilder::XPath::VERSION < 0.09) {
                return HTML::Entities::encode($node->as_XML, q("'<>&));
            } else {
                return $node->as_XML;
            }
        }
        my $html = $node->as_XML;
        $html =~ s!^<.*?>!!;
        $html =~ s!\s*</\w+>\n*$!!;
        return $html;
    } elsif (ref($val) eq 'HASH') {
        my $values;
        for my $key (keys %$val) {
            $values->{$key} = __get_value($node, $val->{$key}, $uri);
        }
        return $values;
    } elsif (ref($val) eq 'ARRAY') {
        my $how   = $val->[0];
        my $value = __get_value($node, $how, $uri);
        for my $filter (@$val[1..$#$val]) {
            $value = run_filter($value, $filter);
        }
        return $value;
    } else {
        Carp::croak "Unknown value type $val";
    }
}

sub run_filter {
    my($value, $filter) = @_;

    ## sub { s/foo/bar/g } is a valid filter
    ## sub { DateTime::Format::Foo->parse_string(shift) } is valid too
    my $callback;
    my $module;

    if (ref($filter) eq 'CODE') {
        $callback = $filter;
        $module   = "$filter";
    } elsif (ref($filter) eq 'Regexp') {
        $callback = sub {
            my @unnamed = shift =~ /$filter/x;
            if (%+) {
                return { %+ };
            } elsif (@unnamed) {
                return shift @unnamed;
            } else {
                return;
            }
        };
        $module   = "$filter";
    } elsif (!ref($filter)) {
        $module = $filter =~ s/^\+// ? $filter : "Web::Scraper::Filter::$filter";
        unless ($module->isa('Web::Scraper::Filter')) {
            $module->require or Carp::croak("Loading $module: $@");
        }
        $callback = sub { $module->new->filter(shift) };
    } elsif (blessed($filter) && $filter->can('filter')) {
        $callback = sub { $filter->filter(shift) };
    } else {
        Carp::croak("Don't know filter type $filter");
    }

    local $_ = $value;
    my $retval = eval { $callback->($value) };
    if ($@) {
        Carp::croak("Filter $module had an error: $@");
    }

    no warnings 'uninitialized';
    # sub { s/foo/bar/ } returns number or PL_sv_no which is stringified to ''
    if (($retval =~ /^\d+$/ and $_ ne $value) or (defined($retval) and $retval eq '')) {
        $value = $_;
    } else {
        $value = $retval;
    }

    return $value;
}

sub is_link_element {
    my($node, $attr) = @_;
    my $link_elements = $HTML::Tagset::linkElements{$node->tag} || [];
    for my $elem (@$link_elements) {
        return 1 if $attr eq $elem;
    }
    return;
}

sub __stub {
    my $func = shift;
    return sub {
        croak "Can't call $func() outside scraper block";
    };
}

*process       = __stub 'process';
*process_first = __stub 'process_first';
*result        = __stub 'result';

1;
__END__

=for stopwords API SCRAPI Scrapi

=head1 NAME

Web::Scraper - Web Scraping Toolkit using HTML and CSS Selectors or XPath expressions

=head1 SYNOPSIS

  use URI;
  use Web::Scraper;
  use Encode;

  # First, create your scraper block
  my $authors = scraper {
      # Parse all TDs inside 'table[width="100%]"', store them into
      # an array 'authors'.  We embed other scrapers for each TD.
      process 'table[width="100%"] td', "authors[]" => scraper {
  	# And, in each TD,
  	# get the URI of "a" element
  	process "a", uri => '@href';
  	# get text inside "small" element
  	process "small", fullname => 'TEXT';
      };
  };

  my $res = $authors->scrape( URI->new("http://search.cpan.org/author/?A") );

  # iterate the array 'authors'
  for my $author (@{$res->{authors}}) {
      # output is like:
      # Andy Adler	http://search.cpan.org/~aadler/
      # Aaron K Dancygier	http://search.cpan.org/~aakd/
      # Aamer Akhter	http://search.cpan.org/~aakhter/
      print Encode::encode("utf8", "$author->{fullname}\t$author->{uri}\n");
  }


The structure would resemble this (visually)

  {
    authors => [
      { fullname => $fullname, link => $uri },
      { fullname => $fullname, link => $uri },
    ]
  }

=head1 DESCRIPTION

Web::Scraper is a web scraper toolkit, inspired by Ruby's equivalent
Scrapi. It provides a DSL-ish interface for traversing HTML documents and
returning a neatly arranged Perl data structure.

The I<scraper> and I<process> blocks provide a method to define what segments
of a document to extract.  It understands HTML and CSS Selectors as well as
XPath expressions.

=head1 METHODS

=head2 scraper

  $scraper = scraper { ... };

Creates a new Web::Scraper object by wrapping the DSL code that will be fired when I<scrape> method is called.

=head2 scrape

  $res = $scraper->scrape(URI->new($uri));
  $res = $scraper->scrape($html_content);
  $res = $scraper->scrape(\$html_content);
  $res = $scraper->scrape($http_response);
  $res = $scraper->scrape($html_element);

Retrieves the HTML from URI, HTTP::Response, HTML::Tree or text
strings and creates a DOM object, then fires the callback scraper code
to retrieve the data structure.

If you pass URI or HTTP::Response object, Web::Scraper will
automatically guesses the encoding of the content by looking at
Content-Type headers and META tags. Otherwise you need to decode the
HTML to Unicode before passing it to I<scrape> method.

You can optionally pass the base URL when you pass the HTML content as
a string instead of URI or HTTP::Response.

  $res = $scraper->scrape($html_content, "http://example.com/foo");

This way Web::Scraper can resolve the relative links found in the document.

Also you can optionally pass HTML::TreeBuilder::XPath attributes (See: L<HTML::TreeBuilder>) as a hash reference.

  $res = $scraper->scrape($html_content, { ignore_unknown => 1 });

And you can also pass both the base URL and attributes.

  $res = $scraper->scrape($html_content, {
                                base_url => "http://example.com/foo"
                                ignore_unknown => 1
                         });

=head2 process

  scraper {
      process "tag.class", key => 'TEXT';
      process '//tag[contains(@foo, "bar")]', key2 => '@attr';
      process '//comment()', 'comments[]' => 'TEXT';
  };

I<process> is the method to find matching elements from HTML with CSS
selector or XPath expression, then extract text or attributes into the
result stash.

If the first argument begins with "//" or "id(" it's treated as an
XPath expression and otherwise CSS selector.

  # <span class="date">2008/12/21</span>
  # date => "2008/12/21"
  process ".date", date => 'TEXT';

  # <div class="body"><a href="http://example.com/">foo</a></div>
  # link => URI->new("http://example.com/")
  process ".body > a", link => '@href';

  # <div class="body"><!-- HTML Comment here --><a href="http://example.com/">foo</a></div>
  # comment => " HTML Comment here "
  #
  # NOTES: A comment nodes are accessed when installed
  # the HTML::TreeBuilder::XPath (version >= 0.14) and/or
  # the HTML::TreeBuilder::LibXML (version >= 0.13)
  process "//div[contains(@class, 'body')]/comment()", comment => 'TEXT';

  # <div class="body"><a href="http://example.com/">foo</a></div>
  # link => URI->new("http://example.com/"), text => "foo"
  process ".body > a", link => '@href', text => 'TEXT';

  # <ul><li>foo</li><li>bar</li></ul>
  # list => [ "foo", "bar" ]
  process "li", "list[]" => "TEXT";

  # <ul><li id="1">foo</li><li id="2">bar</li></ul>
  # list => [ { id => "1", text => "foo" }, { id => "2", text => "bar" } ];
  process "li", "list[]" => { id => '@id', text => "TEXT" };

=head2 process_first

C<process_first> is the same as C<process> but stops when the first matching
result is found.

  # <span class="date">2008/12/21</span>
  # <span class="date">2008/12/22</span>
  # date => "2008/12/21"
  process_first ".date", date => 'TEXT';

=head2 result

C<result> allows one to return not the default value after processing but a single
value specified by a key or a hash reference built from several keys.

  process 'a', 'want[]' => 'TEXT';
  result 'want';

=head1 EXAMPLES

There are many examples in the C<eg/> dir packaged in this distribution.
It is recommended to look through these.

=head1 NESTED SCRAPERS

Scrapers can be nested thus allowing to scrape already captured data.

  # <ul>
  # <li class="foo"><a href="foo1">bar1</a></li>
  # <li class="bar"><a href="foo2">bar2</a></li>
  # <li class="foo"><a href="foo3">bar3</a></li>
  # </ul>
  # friends => [ {href => 'foo1'}, {href => 'foo2'} ];
  process 'li', 'friends[]' => scraper {
    process 'a', href => '@href',
  };

=head1 FILTERS

Filters are applied to the result after processing. They can be declared as
anonymous subroutines or as class names.

  process $exp, $key => [ 'TEXT', sub { s/foo/bar/ } ];
  process $exp, $key => [ 'TEXT', 'Something' ];
  process $exp, $key => [ 'TEXT', '+MyApp::Filter::Foo' ];

Filters can be stacked

  process $exp, $key => [ '@href', 'Foo', '+MyApp::Filter::Bar', \&baz ];

More about filters you can find in L<Web::Scraper::Filter> documentation.

=head1 XML backends

By default L<HTML::TreeBuilder::XPath> is used, this can be replaces by
a L<XML::LibXML> backend using L<Web::Scraper::LibXML> module.

  use Web::Scraper::LibXML;

  # same as Web::Scraper
  my $scraper = scraper { ... };

=head1 AUTHOR

Tatsuhiko Miyagawa E<lt>miyagawa@bulknews.netE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<http://blog.labnotes.org/category/scrapi/>

L<HTML::TreeBuilder::XPath>

=cut
