use strict;
use Test::Base;

use utf8;
use Web::Scraper;
plan tests => 1 * blocks;

filters {
    attr => 'yaml',
    selector => 'chomp',
    expected => [ 'chomp', 'newline' ],
    html     => 'newline',
};

sub newline {
    s/\\n\n/\n/g;
}

run {
    my $block = shift;
    my $s = scraper {
        process $block->selector, want => ($block->want or 'HTML');
        result 'want';
    };
    my $want = $s->scrape($block->html, $block->attr);
    is $want, $block->expected, $block->name;
};

__DATA__

=== no comments with ignore_unknown
--- attr
store_comments: 0
ignore_unknown: 1
--- html
<div><main><!-- hello -->again</main></div>
--- selector
div
--- expected
again

=== ignore_unknown is false
--- attr
ignore_unknown: 0
--- html
<div><main>hello</main></div>
--- selector
div
--- expected
<main>hello</main>

=== ignore_unknown is true
--- attr
ignore_unknown: 1
--- html
<div><main>hello</main></div>
--- selector
div
--- expected
hello

=== select by unknown tag
--- attr
--- html
<div><main>hello</main></div>
--- selector
div > main
--- expected
hello

=== a@href
--- attr
base_url: http://example.com/
--- html
<a id="foo" href="foo.html">bar</a>
--- selector
a#foo
--- want: @href
--- expected
http://example.com/foo.html
