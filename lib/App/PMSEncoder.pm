package App::PMSEncoder;

use 5.10.0;

# 0.49 or above needed for the RT #54203 fix
use Mouse 0.49; # include strict and warnings

use constant PMSENCODER => 'pmsencoder';
use constant {
    CHECK_RESOURCE_EXISTS   => 1,
    DISTRO                  => 'App-PMSEncoder',
    MENCODER_EXE            => 'mencoder.exe',
    PMSENCODER_CONFIG       => PMSENCODER . '.yml',
    PMSENCODER_EXE          => PMSENCODER . '.exe',
    PMSENCODER_LOG          => PMSENCODER . '.log',
    REQUIRE_RESOURCE_EXISTS => 2,
};

# core modules
use Config;
use File::Spec;
use POSIX qw(strftime);

# bundled modules
use HTTP::Simple qw(head get); # FIXME: alias them to http_get, http_head &c. use Sub::Exporter?

# CPAN modules
use File::HomeDir; # technically, this is not always needed, but using it unconditionally simplifies teh code slightly
use IO::All;
use IPC::Cmd 0.56 qw(can_run); # core since 5.10.0, but we need a version that escapes shell arguments correctly
use List::MoreUtils qw(first_index any);
use Method::Signatures::Simple;
use Path::Class qw(file dir);
use YAML::Tiny qw(Load);

# use File::ShareDir;           # not used on Windows
# use Cava::Pack;               # Windows only

our $VERSION = '0.60';          # PMSEncoder version: logged to aid diagnostics
our $CONFIG_VERSION = '0.60';   # croak if the config file needs upgrading; XXX try not to change this too often

# mencoder arguments
has argv => (
    is         => 'rw',
    isa        => 'ArrayRef',
    auto_deref => 1,
);

# the YAML config file as a hash ref
has config => (
    is      => 'rw',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_load_config',
);

# valid extensions for the pmsencoder config file
has config_file_ext => (
    is         => 'ro',
    isa        => 'ArrayRef',
    auto_deref => 1,
    default    => sub { [qw(conf yml yaml)] },
);

# full path to the config file - an exception is thrown if one can't be found
has config_file_path => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    builder => '_build_config_file_path',
);

# the path to the default config file - used as a fallback if no custom config file is found
has default_config_path => (
    is  => 'rw',
    isa => 'Str'
);

# document cache for exec_get
has document => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# IO::All logfile handle
has logfile => (
    is => 'rw',

    # isa => 'IO::All::File',
    # XXX Mouse no likey
);

# full logfile path
has logfile_path => (
    is  => 'rw',
    isa => 'Str',
);

# full path to mencoder binary
has mencoder_path => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    builder => '_build_mencoder_path',
);

# is this running on Windows?
has mswin => (
    is      => 'ro',
    isa     => 'Bool',
    default => ($^O eq 'MSWin32'),
);

# full path to this executable
has self_path => (
    is      => 'rw',
    isa     => 'Str',
    default => $0
);

# symbol table containing user-defined variables and named captures
has stash => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# position in argv of the filename/URI.
# this *must* be constructed lazily i.e. when process_config requests it (via run)
# XXX for a while (squashed bug), it was still being initialised in BUILD,
# a holdover from an earlier version in which the config file was both loaded and
# processed in BUILD
has uri_index => (
    is      => 'rw',
    isa     => 'Int',
    lazy    => 1,
    builder => '_build_uri_index',
);

# full path to the dir searched for the user's config file
has user_config_dir => (
    is  => 'rw',
    isa => 'Str',
);

# add support for a :Raw attribute used to indicate that a handler method
# bound to "operators" in the config file should have its argument passed unprocessed
# (normally hash and array elements are passed piecewise). Actually, we can use this to handle
# any attributes, but only :Raw is currently used.
# this is untidy (Attributes::Storage looks nicer), but attributes.pm is in core (from 5.6),
# so it's one less dependency to worry about

{
    my (%ATTRIBUTES, %ATTRIBUTES_OK);

    # this needs to be initialised before MODIFY_CODE_ATTRIBUTES is called i.e. at compile-time
    BEGIN { %ATTRIBUTES_OK = map { $_ => 1 } qw(Raw) }

    # needs to be a sub as it's called at compile-time
    sub MODIFY_CODE_ATTRIBUTES {
        my ($class, $code, @attrs) = @_;
        my (@keep, @discard);

        # partition attributes into those we handle (i.e. those listed in @ATTRIBUTES) and those we don't
        for my $attr (@attrs) {
            if ($ATTRIBUTES_OK{$attr}) {
                push @keep, $attr;
            } else {
                push @discard, $attr;
            }
        }

        $ATTRIBUTES{$code} = [@keep];
        return @discard;    # return any attributes we don't handle
    }

    # by using %ATTRIBUTES directly we can bypass attributes::get and FETCH_CODE_ATTRIBUTES
    method has_attribute($code, $attribute) {
        any { $_ eq $attribute } @{ $ATTRIBUTES{$code} || [] };
    }
}

method BUILD {
    my $logfile_path = $self->logfile_path(file(File::Spec->tmpdir, PMSENCODER_LOG)->stringify);

    $self->logfile(io($logfile_path));
    $self->logfile->append($/) if (-s $logfile_path);
    $self->debug(PMSENCODER . " $VERSION ($^O)");

    # on Win32, it might make sense for the config file to be in $PMS_HOME, typically C:\Program Files\PS3 Media Server
    # Unfortunately, PMS' registry entries are currently broken, so we can't rely on them (e.g. we
    # can't use Win32::TieRegistry):
    #
    #     http://code.google.com/p/ps3mediaserver/issues/detail?id=555
    #
    # Instead we bundle the default (i.e. fallback) config file (and mencoder.exe) in $PMSENCODER_HOME/res.
    # we use the private _get_resource_path method to abstract away the platform-specifics

    # initialize resource handling and fixup the stored $0 on Windows
    if ($self->mswin) {
        require Cava::Pack;
        Cava::Pack::SetResourcePath('res');
        $self->self_path(file($self->get_resource_path(''), File::Spec->updir, PMSENCODER_EXE)->absolute->stringify);

        # declare a private method - at runtime!
        method _get_resource_path ($name) {
            Cava::Pack::Resource($name)
        }
    } else {
        require File::ShareDir; # no need to worry about this not being picked up by Cava as it's non-Windows only

        # declare a private method - at runtime!
        method _get_resource_path($name) {
            File::ShareDir::dist_file(DISTRO, $name)
        }
    }

    my $data_dir = File::HomeDir->my_data;

    $self->user_config_dir(dir($data_dir, '.' . PMSENCODER)->stringify);
    $self->default_config_path($self->get_resource_path(PMSENCODER_CONFIG, REQUIRE_RESOURCE_EXISTS));

    my @argv = $self->argv();
    $self->debug('path: ' . $self->self_path . (@argv ? " @argv" : ''));

    return $self;
}

method get_resource_path ($name, $exists) {
    my $path = $self->_get_resource_path($name);

    if ($exists) {
        if ($exists == CHECK_RESOURCE_EXISTS) {
            return (-f $path) ? $path : undef;
        } elsif ($exists == REQUIRE_RESOURCE_EXISTS) {
            return (-f $path) ? $path : $self->fatal("can't find resource: $name");
        } else {    # internal error - shouldn't get here
            $self->fatal("invalid flag for get_resource_path($name): $exists");
        }
    } else {
        return $path;
    }
}

method get_resource ($name) {
    my $path = $self->get_resource_path($name, REQUIRE_RESOURCE_EXISTS);

    return io($path)->chomp->slurp();
}

# dump various config settings - useful for troubleshooting
method version {
    my $user_config_dir = $self->user_config_dir || '<undef>';    # may be undef according to the File::HomeDir docs

    print STDOUT
      PMSENCODER, ":            $VERSION ($^O $Config{osvers})", $/,
      'perl:                  ', sprintf('%vd', $^V), $/,
      'config file version:   ', $self->config->{version}, $/,    # sanity-checked by _process_config
      'config file:           ', $self->config_file_path(),    $/,
      'default config file:   ', $self->default_config_path(), $/,
      'logfile:               ', $self->logfile_path(),        $/,
      'mencoder path:         ', $self->mencoder_path(),       $/,
      'user config directory: ', $user_config_dir, $/,
}

# squashed bug: this has to be created lazily i.e. more fallout from allowing argv to be set after initialisation.
# the first method to call uri_index is process_config via run; it's then called by various exec_* methods
method _build_uri_index {

    # 4 is hardwired in net.pms.encoders.MEncoderVideo.launchTranscode
    # FIXME: document where the hardwiring of the 0th index for the URI is found
    $self->isdef('prefer-ipv4') ? 0 : 4;
}

method _build_mencoder_path {
    my $ext = $Config{_exe};

    # we look for mencoder in these places (in descending order of priority):
    #
    # 1) mencoder_path in the config file
    # 2) the path indicated by the environment variable $MENCODER_PATH
    # 3) the current working directory (prepended to the search path by IPC::Cmd::can_run)
    # 4) $PATH (via IPC::Cmd::can_run)
    # 5) the default (bundled) mencoder - currently only available on Windows

    $self->config->{mencoder_path}
      || $ENV{MENCODER_PATH}
      || can_run('mencoder')
      || $self->get_resource_path("mencoder$ext", CHECK_RESOURCE_EXISTS)
      || $self->fatal("can't find mencoder");
}

method _build_config_file_path {
    # first: check the environment variable (should contain the absolute path)
    if (exists $ENV{PMSENCODER_CONFIG}) {
        my $config_file_path = $ENV{PMSENCODER_CONFIG};

        if (-f $config_file_path) {
            return $config_file_path;
        } else {
            $self->fatal("invalid PMSENCODER_CONFIG environment variable ($config_file_path): file not found");
        }
    }

    # second: search for it in the user's home directory e.g. ~/.pmsencoder/pmsencoder.yml
    my $user_config_dir = $self->user_config_dir();

    if (defined $user_config_dir) { # not guaranteed to be defined
        for my $ext ($self->config_file_ext) { # allow .yml, .yaml, and .conf
            my $config_file_path = file($user_config_dir, PMSENCODER . ".$ext")->stringify;
            return $config_file_path if (-f $config_file_path);
        }
    } else {
        $self->debug("can't find user config dir"); # should usually be defined; worth noting if it's not
    }

    # finally, fall back on the config file installed with the distro - this should always be available
    my $default = $self->default_config_path() || $self->fatal("can't find default config file");

    if (-f $default) {
        return $default;
    } else { # XXX shouldn't happen
        $self->fatal("can't find default config file: $default");
    }
}

method debug ($message) {
    my $now = strftime("%Y-%m-%d %H:%M:%S", localtime);

    $self->logfile->append("$now: $$: $message", $/);
}

method fatal ($message) {
    $self->debug("ERROR: $message");
    die $self->self_path . ": $VERSION: $$: ERROR: $message", $/;
}

method isdef ($name) {
    my $argv = $self->argv;
    my $index = first_index { $_ eq "-$name" } $self->argv;

    return ($index != -1);
}

method isopt ($arg) {
    return (defined($arg) && (substr($arg, 0, 1) eq '-'));
}

method run {
    my $mencoder = $self->mencoder_path();

    # modify $self->argv according to the recipes in the config file
    $self->process_config();

    # XXX obviously, this must be retrieved *after* process_config has performed any modifications
    my @argv = $self->argv();

    $self->debug("exec: $mencoder" . (@argv ? " @argv" : ''));

    # IPC::Cmd's use of IPC::Run is broken: https://rt.cpan.org/Ticket/Display.html?id=54184
    local $IPC::Cmd::USE_IPC_RUN = 0;

    my ($ok, $err) = IPC::Cmd::run(
        command => [ $mencoder, @argv ],
        verbose => 1
    );

    if ($ok) {
        $self->debug('ok');
    } else {
        $self->fatal("can't exec mencoder: $err");
    }

    exit 0;
}

# XXX this is the only builder whose name doesn't begin with _build
method _load_config {
    my $config_file = $self->config_file_path();

    # XXX Try::Tiny?
    $self->debug("loading config: $config_file");
    my $yaml = eval { io($config_file)->slurp() };
    $self->fatal("can't open config: $@") if ($@);
    my $config = eval { Load($yaml) };
    $self->fatal("can't load config: $@") if ($@);
    return $config || $self->fatal("config is undefined");
}

method process_config {
    $self->debug('processing config');

    my $uri    = $self->argv->[ $self->uri_index ];
    my $config = $self->config();

    # FIXME: this blindly assumes the config file is sane for the most part
    # XXX use Kwalify?

    my $version = $config->{version};

    $self->fatal("no version found in the config file") unless (defined $version);
    $self->debug("config file version: $version");
    $self->fatal("config file is out of date; please upgrade") unless ($version && ($version >= $CONFIG_VERSION));

    if (defined $uri) {
        my $profiles = $config->{profiles};

        if ($profiles) {
            for my $profile (@$profiles) {
                my $profile_name = $profile->{name};
                my $match        = $profile->{match};

                if (defined($match) && ($uri =~ $match)) {
                    $self->debug("matched profile: $profile_name");

                    # merge and log any named captures
                    while (my ($named_capture_key, $named_capture_value) = each(%+)) {
                        $self->exec_let($named_capture_key, $named_capture_value);
                    }

                    my $options = $profile->{options};
                    $options = [ $options ] unless (ref($options) eq 'ARRAY');

                    for my $hash (@$options) {
                        while (my ($key, $value) = each(%$hash)) {
                            my $operator = $self->can("exec_$key");

                            $self->fatal("invalid operator: $key") unless ($operator);

                            if (ref($value) && not($self->has_attribute($operator, 'Raw'))) {
                                if ((ref $value) eq 'HASH') {
                                    while (my ($k, $v) = each(%$value)) {
                                        $operator->($self, $k, $v);
                                    }
                                } else {
                                    for my $v (@$value) {
                                        $operator->($self, $v);
                                    }
                                }
                            } elsif (defined $value) {
                                $operator->($self, $value);
                            } else {
                                $operator->($self);
                            }
                        }
                    }
                }
            }
        } else {
            $self->debug('no profiles defined');
        }
    } else {
        $self->debug('no URI defined');
    }
}

################################# MEncoder Options ################################

# extract the media URI - see http://stackoverflow.com/questions/1883737/getting-an-flv-from-youtube-in-net
method exec_youtube ($formats) :Raw {
    my $uri   = $self->argv->[ $self->uri_index ];
    my $stash = $self->stash;
    my ($video_id, $t) = @{$stash}{qw(video_id t)};
    my $found = 0;

    # via http://www.longtailvideo.com/support/forum/General-Chat/16851/Youtube-blocked-http-youtube-com-get-video
    #
    # No &fmt = FLV (very low)
    # &fmt=5  = FLV (very low)
    # &fmt=6  = FLV (doesn't always work)
    # &fmt=13 = 3GP (mobile phone)
    # &fmt=18 = MP4 (normal)
    # &fmt=22 = MP4 (hd)
    #
    # see also:
    #
    #     http://tinyurl.com/y8rdcoy
    #     http://userscripts.org/topics/18274

    for my $fmt (@$formats) {
        my $media_uri = "http://www.youtube.com/get_video?fmt=$fmt&video_id=$video_id&t=$t";
        next unless (head $media_uri);
        $self->exec_uri($media_uri); # set the new URI
        $found = 1;
        last;
    }

    $self->fatal("can't retrieve YouTube video from $uri") unless ($found);
}

method exec_set ($name, $value) {
    $name = "-$name";

    my $argv = $self->argv;
    my $index = first_index { $_ eq $name } @$argv;

    if ($index == -1) {
        if (defined $value) {
            $self->debug("adding $name $value");
            push @$argv, $name, $value;    # FIXME: encapsulate
        } else {
            $self->debug("adding $name");
            push @$argv, $name;            # FIXME: encapsulate
        }
    } elsif (defined $value) {
        $self->debug("setting $name to $value");
        $argv->[ $index + 1 ] = $value;    # FIXME: encapsulate
    }
}

method exec_replace ($name, $search, $replace) {
    $name = "-$name";

    my $argv = $self->argv();
    my $index = first_index { $_ eq $name } @$argv;

    if ($index != -1) {
        $self->debug("replacing $search with $replace in $name");
        $argv->[ $index + 1 ] =~ s{$search}{$replace};    # FIXME: encapsulate
    }
}

method exec_remove ($name) {
    $name = "-$name";

    my @argv  = $self->argv;
    my $nargs = @argv;
    my @keep;

    while (@argv) {
        my $arg = shift @argv;

        if ($self->isopt($arg)) { # -foo ...
            if (@argv && not($self->isopt($argv[0]))) {    # -foo bar
                my $value = shift @argv;

                if ($arg ne $name) {
                    push @keep, $arg, $value;
                }
            } elsif ($arg ne $name) {                      # just -foo
                push @keep, $arg;
            }
        } else {
            push @keep, $arg;
        }
    }

    if (@keep < $nargs) {
        $self->debug("removing $name");
        $self->argv(\@keep);
    }
}

# define a variable in the stash
method exec_let ($name, $value) {
    $self->debug("setting \$$name to $value");
    $self->stash->{$name} = $value;
}

# define a variable in the stash by extracting a value from the document pointed to by the current URI
method exec_get ($key, $value) {
    my $uri      = $self->argv->[ $self->uri_index ];    # XXX need a uri attribute that does the right thing(s)
    my $document = do {                                  # cache for subsequent matches
        unless (exists $self->document->{$uri}) {
            $self->document->{$uri} = get($uri) || $self->fatal("can't retrieve $uri");
        }
        $self->document->{$uri};
    };

    # key: 'value (?<named_capture>...)'
    if (defined $value) {
        $self->debug("extracting \$$key from $uri");
        my ($extract) = $document =~ /$value/;
        $self->exec_let($key, $extract);
    } else {
        $document =~ /$key/;
        while (my ($named_capture_key, $named_capture_value) = (each %+)) {
            $self->exec_let($named_capture_key, $named_capture_value);
        }
    }
}

# XXX unused/untested
method exec_delete ($key) {
    my $stash = $self->stash;

    if (defined $key) {
        if (exists $stash->{$key}) {
            delete $stash->{$key};
        } else {
            $self->debug("can't delete stash entry: no such key: $key");
        }
    } else {
        $self->debug("can't delete stash entry: undefined key");
    }
}

# set the URI, performing any variable substitutions
method exec_uri ($uri) {
    while (my ($key, $value) = each(%{ $self->stash })) {
        my $search = qr{(?:(?:\$$key\b)|(?:\$\{$key\}))};
        if ($uri =~ $search) {
            $self->debug("replacing \$$key with '$value' in $uri");
            $uri =~ s{$search}{$value}g;
        }
    }

    $self->argv->[ $self->uri_index ] = $uri;
}

1;

__END__

=head1 NAME

App::PMSEncoder - MEncoder wrapper for PS3 Media Server

=head1 SYNOPSIS

    my $pmsencoder = App::PMSEncoder->new({ argv => \@ARGV });

    $pmsencoder->run();

=head1 DESCRIPTION

This is a helper script for PS3 Media Server that restores support for Web video streaming via mencoder.

See here for more details: http://github.com/chocolateboy/pmsencoder

=head1 AUTHOR

chocolateboy <chocolate@cpan.org>

=head1 SEE ALSO

=over

=item * L<FFmpeg|FFmpeg>

=back

=head1 VERSION

0.60

=cut