package Text::EventDiary;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(parse_event_diary);

our %SPEC;

$SPEC{parse_event_diary} = {
    v => 1.1,
    summary => 'Parse event diary',
    args => {
        diary => {
            summary => 'Diary source text',
            schema => 'str*',
            req => 1,
        },
        spec => {
            summary => 'Diary specification',
            schema => 'hash*',
            req => 1,
        },
    },
};
sub parse_event_diary {
    my %args = @_;

    my $diary = $args{diary};
    defined $diary or return [400, "Please specify diary"];

    my $spec = $args{spec};
    defined $spec or return [400, "Please specify spec"];

    my %eventspecs; # key=name (including alias)
    for my $name (keys %{ $spec->{events} }) {
        my $eventspec = $spec->{events}{$name};
        $eventspecs{$name} and warn "Duplicate event name/alias '$name'";
        $eventspecs{$name} = $eventspec;
        if ($eventspec->{aliases}) {
            for my $aliasname (keys %{ $eventspec->{aliases} }) {
                $eventspecs{$aliasname} and warn "Duplicate event name/alias '$aliasname'";
                $eventspecs{$aliasname} = $eventspec;
            }
        }
    }

    my @unparsed_entries;
  SPLIT_ENTRIES: {
        if ($diary =~ /\S\R\R+\S/) {
            # there is a blank line between non-blanks, assume entries are
            # written in paragraphs
            @unparsed_entries = split /\R\R+/, $args{entries};
            for (@unparsed_entries) {
                s/\R+/ /g;
                s/\s+\z//;
            }
        } else {
            # there are no blank lines, assume entries are written as individual
            # lines
            @unparsed_entries = split /^/, $args{entries};
        }
        for (@unparsed_entries) {
            s/\R+/ /g;
            s/\s+\z//;
        }
    } # SPLIT_ENTRIES

  PARSE_ENTRIES: {
        my $i = 0;
        for my $uentry (@unparsed_entries) {
            my $uentry0 = $uentry;
            $i++;
            my $time;
            $uentry =~ s/\A(?:(\d{4})-(\d{2})-(\d{2})T)?(\d\d)[:.]?(\d\d)(?:-(\d\d)[:.]?(\d\d))?\s*//
                or return [400, "Entry #$i: invalid time, please start with YYYY-MM-DD\"T\"hh:mm or hh:mm or hhmm: $uentry0"];
            my ($Y, $M, $D, $h, $m, $h2, $m2) = ($1, $2, $3, $4, $5, $6, $7);
            $uentry =~ s/(\w+):?\s*//
                or return [400, "Entry #$i: event (e.g. drink, urinate) expected: $uentry"];
            my $event = $1;
            if    ($event eq 'u' || $event eq 'urin') { $event = 'urinate' }
            elsif ($event eq 'd') { $event = 'drink' }
            elsif ($event eq 'c') { $event = 'comment' }
            $event =~ /\A(drink|eat|poop|urinate|comment)\z/
                or return [400, "Entry #$i: unknown event '$event', please choose eat|drink|poop|urinate|comment"];

            my $parsed_entry = {
                # XXX check that time is monotonically increasing
                time => sprintf("%02d.%02d", $h, $m),
                _h    => $h,
                _m    => $m,
                _time => $h*60 + $m,
                _raw  => $uentry0,
            };

            # scrape key-value pairs from unparsed entry
            my %kv;
            while ($uentry =~ /(\w+)=(.+?)(?=[,.]?\s+\w+=|[.]?\s*\z)/g) {
                $kv{$1} = $2;
            }
            #use DD; dd \%kv;

            for my $k (qw/vol type comment urgency color/) {
                if (defined $kv{$k}) {
                    $parsed_entry->{$k} = $kv{$k};
                }
            }

            $uentry =~ /\b(\d+)ml\b/     and $parsed_entry->{vol}     //= $1;
            $uentry =~ /\bv(\d+)\b/      and $parsed_entry->{vol}     //= $1;
            $uentry =~ /\bu([0-9]|10)\b/ and $parsed_entry->{urgency} //= $1;
            $uentry =~ /\bc([0-6])\b/    and $parsed_entry->{color}   //= do {
                if    ($1 == 0) { 'clear' } # very good
                elsif ($1 == 1) { 'light yellow' } # good
                elsif ($1 == 2) { 'yellow' } # fair
                elsif ($1 == 3) { 'dark yellow' } # light dehydrated
                elsif ($1 == 4) { 'amber' } # dehydrated
                elsif ($1 == 5) { 'brown' } # very dehydrated
                elsif ($1 == 6) { 'red' } # severe dehydrated
            };

            if ($event eq 'drink') {
                return [400, "Entry #$i: please specify volume for $event"]
                    unless defined $parsed_entry->{vol};
                $parsed_entry->{type} //= "water";
                push @intakes, $parsed_entry;
            } elsif ($event eq 'eat') {
                $parsed_entry->{type} = "food";
                push @intakes, $parsed_entry;
            } elsif ($event eq 'urinate') {
                return [400, "Entry #$i: please specify volume for $event"]
                unless defined $parsed_entry->{vol};
                $parsed_entry->{"ucomment"} = "poop" . ($parsed_entry->{comment} ? ": $parsed_entry->{comment}" : "");
                push @urinations, $parsed_entry;
            }
        }
    } # PARSE_ENTRIES

    if ($args{_raw}) {
        return [200, "OK", {
            intakes => \@intakes,
            urinations => \@urinations,
        }];
    }

    my @rows;
    my $ivol_cum = 0;
    my $uvol_cum = 0;
    my $prev_utime;
    my $num_drink = 0;
    my $num_urinate = 0;
  GROUP_INTO_HOURS: {
        my $h = do {
            my $hi = @intakes    ? $intakes[0]{_h}    : undef;
            my $hu = @urinations ? $urinations[0]{_h} : undef;
            my $h = $hi // $hu;
            $h = $hi if defined $hi && $hi < $h;
            $h = $hu if defined $hu && $hu < $h;
            $h;
        };
        while (1) {
            last unless @intakes || @urinations;

            my @hour_rows;
            push @hour_rows, {time => sprintf("%02d.00-%02d.00", $h, $h+1 <= 23 ? $h+1 : 0)};

            my $j = 0;
            while (@intakes && $intakes[0]{_h} == $h) {
                my $entry = shift @intakes;
                $hour_rows[$j]{"intake type"} = $entry->{type};
                $hour_rows[$j]{itime}         = $entry->{time};
                $hour_rows[$j]{"icomment"}    = $entry->{comment};
                if (defined $entry->{vol}) {
                    $num_drink++;
                    $hour_rows[$j]{"ivol (ml)"}   = $entry->{vol};
                    $ivol_cum += $entry->{vol};
                    $hour_rows[$j]{"ivol cum"}    = $ivol_cum;
                }
                $j++;
            }

            $j = 0;
            while (@urinations && $urinations[0]{_h} == $h) {
                my $entry = shift @urinations;
                $hour_rows[$j]{"urin/defec time"}  = $entry->{time};
                $hour_rows[$j]{"color"}            = $entry->{color};
                $hour_rows[$j]{"ucomment"}         = $entry->{comment};
                $hour_rows[$j]{"urgency (0-10)"}   = $entry->{urgency};
                if (defined $entry->{vol}) {
                    $num_urinate++;
                    $hour_rows[$j]{"uvol (ml)"}    = $entry->{vol};
                    $uvol_cum += $entry->{vol};
                    $hour_rows[$j]{"uvol cum"}     = $uvol_cum;
                    my $mins_diff;
                    if (defined $prev_utime) {
                        $mins_diff = $prev_utime > $entry->{_time} ? (24*60+$entry->{_time} - $prev_utime) : ($entry->{_time} - $prev_utime);
                    }
                    #$hour_rows[$j]{"utimediff"}    = $mins_diff;
                    $hour_rows[$j]{"urate (ml/h)"} = defined($prev_utime) ?
                        sprintf("%.0f", $entry->{vol} / $mins_diff * 60) : undef;
                }
                $j++;

                $prev_utime = $entry->{_time};
            }
            push @rows, @hour_rows;
            $h++;
            $h = 0 if $h >= 24;
        }
    } # GROUP_INTO_HOURS

  ADD_SUMMARY_ROWS: {
        push @rows, {};

        push @rows, {
            time => 'freq drink/urin',
            'itime' => $num_drink,
            'urin/defec time' => $num_urinate,
        };
        push @rows, {
            time => 'avg (ml)',
            'ivol (ml)' => sprintf("%.0f", $num_drink   ? $ivol_cum / $num_drink   : 0),
            'uvol (ml)' => sprintf("%.0f", $num_urinate ? $uvol_cum / $num_urinate : 0),
        };
    }

    # return result

    [200, "OK", \@rows, {
        'table.fields' => [
            'time',
            'intake type',
            'itime',
            'ivol (ml)',
            'ivol cum',
            'icomment',
            'urin/defec time',
            'uvol (ml)',
            'uvol cum',
            'urate (ml/h)',
            'color',
            'urgency (0-10)',
            'ucomment',
        ],
        'table.field_aligns' => [
            'left', #'time',
            'left', #'intake type',
            'left', #'itime',
            'right', #'ivol (ml)',
            'right', #'ivol cum',
            'left', #'icomment',
            'left', #'urin/defec time',
            'right', #'uvol (ml)',
            'right', #'uvol cum',
            'right', #'urate (ml/h)',
            'left', #'color',
            'left', #'urgency (0-10)',
            'left', #'ucomment',
        ],
    }];
}

1;
# ABSTRACT:

=head1 SYNOPSIS

 use Text::EventDiary qw(parse_event_diary);

 my $diary = <<'EOF';
 0750 drink 300ml
 0755 u v300 c1 u3
 0815 eat: light breakfast with salad and a cup of orange juice
 0830 drink 300ml
 1003 u v200 c1 u3
 EOF

 my $res = parse_event_diary(
     diary => $diary,
     spec  => {
         events => {
             drink => {
                 attrs => {
                     type => {schema=>'str*', default=>'water'},
                     vol  => {schema=>'uint*', req=>1, shortcuts=>[
                         {re=>qr/\bv(\d+)\b/ , code=>sub { my ($attrs, $m) = @_; $attrs->{vol} = $m->[1] }},
                         {re=>qr/\b(\d+)ml\b/, code=>sub { my ($attrs, $m) = @_; $attrs->{vol} = $m->[1] }},
                     ],
                 },
                 aliases => {
                     d => {},
                     dr => {},
                 },
             },
             eat => {
                 attrs => {
                 },
             },
             poop => {
                 attrs => {
                 },
             },
             urinate => {
                 attrs => {
                     vol  => {schema=>'uint*', req=>1, shortcuts=>[
                         {re=>qr/\bv(\d+)\b/ , code=>sub { my ($attrs, $m) = @_; $attrs->{vol} = $m->[1] }},
                         {re=>qr/\b(\d+)ml\b/, code=>sub { my ($attrs, $m) = @_; $attrs->{vol} = $m->[1] }},
                     ],
                     color => {schema=>'str*', shortcuts=>[
                         {re=>qr/\bc([0-6])\b/, code=>sub {
                             my ($attrs, $m) = @_;
                             $attrs->{color} = $m->[1]==0 ? 'clear' : $m->[1]==1 ? 'light yellow' : $m->[1]==2 ? 'yellow' : $m->[1]==3 ? 'dark yellow' : $m->[1]==4 ? 'orange' : $m->[1]==5 ? 'brown' : 'red';
                         }},
                     ],
                 },
             },
         },
         # common event attributes
         attrs => {
             comment => {schema=>'str*'},
         },
     },
 );


=head1 DESCRIPTION


=head1 EVENT DIARY SPECIFICATION

Diary is a text containing lines of B<entries> or paragraphs of entries. If
there is a blank line, entries are assumed to be in paragraphs; otherwise they
are assumed to be single line each. When entries are written in paragraphs, they
will be reformatted to be single lines first during parsing.

Each entry begins with a B<timestamp>. Timestamp is one of:

 YYYY-MM-DD"T"hh:mm
 YYYY-MM-DD"T"hh:mm-H2:m2
 hh:mm
 hh:mm-h2:m2
 hhmm
 hhmm-h2m2

where hh is in 24-hour format. Examples:

 2020-12-14T10:12
 10:12
 1012
 10:12-10:24

Entries must be written chronologically.

After timestamp, whitespace (one or more spaces) and B<event name> must appear.
Examples of event name: C<urinate>, C<drink> (for a bladder diary), C<sleep>,
C<wake>, C<rise> (for a sleep diary).

Only known events, which are defined in the diary specification, are allowed.

An event name can have aliases (usually shorthand), e.g. C<u> for C<urinate>,
C<d> for C<drink>, and so on.

After an event name, free text can follow (e.g. description, comment, etc).
Attributes (pairs of name and values separated by C<=>) will be extracted from
the free text. Attribute name should be a single word (/\b\w+\b/) while value
can be double-quoted text or text that is ended by the nearest comma, semicolon,
or period. Examples:

 0915 drink type=tea vol=300, pretty thirsty.

Attributes are "type" (value "tea") and "vol" (value 300).

 0915 d type=tea vol=300, comment="pretty thirsty, haven't drunk for a few
 hours"

Attributes are "type" (value "tea"), "vol" (value 300), and "comment" (value
"pretty thirsty, haven't drunk for a few hours").

The diary specification also defines what keys are allowed and the type (schema)
of each key.

To ease typing, patterns can also be defined to extract keys and values from the
free text. For example /\bv\d+\b/ is defined as a shorthand to write the C<vol>
key:

 0915 d v300


=head1 KEYWORDS


=head1 SEE ALSO
