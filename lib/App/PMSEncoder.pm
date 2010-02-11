package App::PMSEncoder;

use 5.10.0;

# 0.49 or above needed for the RT #54203 fix
use Mouse 0.49; # include strict and warnings

use constant PMSENCODER => 'pmsencoder';
use constant {
    CHECK_RESOURCE_EXISTS   => 1,
    DISTRO                  => 'App-PMSEncoder',
    FILE_INDEX              => 4,
    MENCODER_EXE            => 'mencoder.exe',
    PMSENCODER_CONFIG       => PMSENCODER . '.yml',
    PMSENCODER_EXE          => PMSENCODER . '.exe',
    PMSENCODER_LOG          => PMSENCODER . '.log',
    REQUIRE_RESOURCE_EXISTS => 2,
    URI_INDEX               => 0,
};

# core modules
use Config;
use File::Spec;
use POSIX qw(strftime);

# CPAN modules
use File::HomeDir; # technically, this is not always needed, but using it unconditionally simplifies the code slightly
use IO::All;
use IPC::Cmd qw(can_run);
use IPC::System::Simple 1.20 qw(systemx); # 
use List::MoreUtils qw(first_index any);
use Method::Signatures::Simple;
use Path::Class qw(file dir);
use YAML::Tiny qw(Load); # not the best YAML processor, but good enough, and the easiest to install

# use File::ShareDir;           # not used on Windows
# use Cava::Pack;               # Windows only
# use LWP::Simple qw(head get)  # loaded on demand

our $VERSION = '0.70';          # PMSEncoder version: logged to aid diagnostics
our $CONFIG_VERSION = '0.70';   # croak if the config file needs upgrading; XXX try not to change this too often

# mencoder arguments
has argv => (
    is         => 'rw',
    isa        => 'ArrayRef',
    auto_deref => 1,
    trigger    => method($argv) {
        $self->debug('argv: ' . (@$argv ? "@$argv" : ''));
    },
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
    default => sub { eval { require Cava::Pack; 1 } }
);

# full path to this executable
has self_path => (
    is      => 'rw',
    isa     => 'Str',
    default => $0
);

# symbol table containing user-defined variables and named captures
has stash => (
    is         => 'rw',
    isa        => 'HashRef',
    default    => sub { {} },
    auto_deref => 1,
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
        Cava::Pack::SetResourcePath('res');

        # declare a private method - at runtime!
        method _get_resource_path($name) {
            Cava::Pack::Resource($name)
        }

        # XXX squashed bug: make sure _get_resource_path is defined before (indirectly) using it to set self_path
        $self->self_path(file($self->get_resource_path(''), File::Spec->updir, PMSENCODER_EXE)->absolute->stringify);
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
    $self->debug('path: ' . $self->self_path);

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
# we should leave this as late as possible e.g. (shouldn't happen but could) in case the args method is called multiple times
method _build_uri_index {
    # 4 is hardwired in net.pms.encoders.MEncoderVideo.launchTranscode
    # FIXME: document where the hardwiring of the 0th index for the URI is found
    $self->isdef('prefer-ipv4') ? URI_INDEX : FILE_INDEX;
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
    # modify $self->argv according to the recipes in the config file
    $self->process_config();

    # FIXME: allow this to be set via the stash i.e. conditionally (and thus remove the global mencoder_path setting)
    my $mencoder = $self->mencoder_path();

    # XXX obviously, this must be retrieved *after* process_config has performed any modifications
    my $argv = $self->argv();

    # now update the URI from the value in the stash
    my $stash = $self->stash;
    unshift @$argv, $stash->{uri}; # always set it as the first argument

    $self->debug("exec: $mencoder" . (@$argv ? " @$argv" : ''));

    eval { systemx($mencoder, @$argv) };

    if ($@) {
        $self->fatal("can't exec mencoder: $@");
    } else {
        $self->debug('ok');
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

method exec_match($hash) {
    my $old_stash = { $self->stash() }; # shallow copy - good enough as there are no reference values (currently)
    my $stash = $self->{stash};
    my $match = 1;

    while (my ($key, $value) = each (%$hash)) { 
        if ((defined $key) && (defined $value) && (exists $stash->{$key}) && ($stash->{$key} =~ $value)) {
            # merge and log any named captures
            while (my ($named_capture_key, $named_capture_value) = each(%+)) {
                $self->exec_let($named_capture_key, $named_capture_value); # updates $stash
            }
        } else {
            $self->stash($old_stash);
	    $match = 0;
	    last;
        }
    }

    return $match;
}

method initialize_stash() {
    my $stash = $self->stash();
    my $argv  = $self->argv();
    my $uri_index = $self->uri_index;
    my $uri   = splice @$argv, $uri_index, 1; # *remove* the URI - restored in run()
    my $file_or_uri = ($uri_index == URI_INDEX) ? 'uri' : 'file';

    $self->debug("$file_or_uri: $uri");

    # FIXME: should probably use a naming convention to distinguish builtin names from user-defined names
    $stash->{uri} = $uri;
    $stash->{context} = (-t STDIN) ? 'CLI' : 'PMS';
}

method process_config {
    # initialize the stash i.e. setup entries for uri, context &c. that may be matched in the config file
    $self->initialize_stash();

    my $config = $self->config();

    # FIXME: this blindly assumes the config file is sane for the most part
    # XXX use Kwalify?

    my $version = $config->{version};

    $self->fatal("no version found in the config file") unless (defined $version);
    $self->debug("config file version: $version");
    $self->fatal("config file is out of date; please upgrade") unless ($version && ($version >= $CONFIG_VERSION));

    my $profiles = $config->{profiles};

    if ($profiles) {
        for my $profile (@$profiles) {
            my $profile_name = $profile->{name};

            unless (defined $profile_name) {
                $self->debug('profile name not defined');
                next;
            }

            my $match = $profile->{match};

            unless ($match) {
                $self->debug("nivalid profile: no match supplied for: $profile_name");
                next;
            }

            # may update the stash if successful
            next unless ($self->exec_match($match));

            $self->debug("matched profile: $profile_name");

            my $options = $profile->{options};

            unless ($options) {
                $self->debug("invalid profile: no options defined for: $profile_name");
                next;
            }

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
    } else {
        $self->debug('no profiles defined');
    }
}

################################# MEncoder Options ################################

# extract the media URI - see http://stackoverflow.com/questions/1883737/getting-an-flv-from-youtube-in-net
method exec_youtube ($formats) :Raw {
    my $stash = $self->stash;
    my $uri   = $stash->{uri};
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

    if (@$formats) {
        require LWP::Simple;

        for my $fmt (@$formats) {
            my $media_uri = "http://www.youtube.com/get_video?fmt=$fmt&video_id=$video_id&t=$t";
            next unless (LWP::Simple::head $media_uri);
            $stash->{uri} = $media_uri; # set the new URI
            $found = 1;
            last;
        }
    } else {
        $self->fatal("no formats defined for $uri");
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
            push @$argv, $name, $value;    # FIXME: encapsulate @argv handling
        } else {
            $self->debug("adding $name");
            push @$argv, $name;            # FIXME: encapsulate @argv handling
        }
    } elsif (defined $value) {
        $self->debug("setting $name to $value");
        $argv->[ $index + 1 ] = $value;    # FIXME: encapsulate @argv handling
    }
}

# TODO: handle undef, a single hashref and an array of hashrefs
method exec_replace ($name, $hash) {
    $name = "-$name";

    my $argv = $self->argv();
    my $index = first_index { $_ eq $name } @$argv;

    if ($index != -1) {
        while (my ($search, $replace) = each(%$hash)) {
            $self->debug("replacing $search with $replace in $name");
            $argv->[ $index + 1 ] =~ s{$search}{$replace}; # FIXME: encapsulate @argv handling
        }
    }
}

method exec_remove ($name) {
    $name = "-$name";

    my $argv = $self->argv; # modify the reference to bypass the setter's logging if we change it
    my @argv  = @$argv; # but create a working copy we can modify in the meantime
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
	@$argv = @keep; # bypass setter logging
    }
}

# define a variable in the stash, performing any variable substitution
method exec_let ($name, $value) {
    my $stash = $self->stash();
    $self->debug("setting \$$name to $value");

    while (my ($key, $replace) = each(%$stash)) {
        my $search = qr{(?:(?:\$$key\b)|(?:\$\{$key\}))};

        if ($value =~ $search) {
            $self->debug("replacing \$$key with '$replace' in $value");
            $value =~ s{$search}{$replace}g;
        }
    }

    $stash->{$name} = $value;
    $self->debug("set \$$name to $value");
}

# define a variable in the stash by extracting a value from the document pointed to by the current URI
method exec_get ($key, $value) {
    my $stash = $self->stash;
    my $uri   = $stash->{uri} || $self->fatal("can't perform get op: no URI defined"); 

    my $document = do { # cache for subsequent matches
        unless (exists $self->document->{$uri}) {
            require LWP::Simple;
            $self->document->{$uri} = LWP::Simple::get($uri) || $self->fatal("can't retrieve URI: $uri");
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

0.70

=cut
