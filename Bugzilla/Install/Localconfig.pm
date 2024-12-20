# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Install::Localconfig;

# NOTE: This package may "use" any modules that it likes. However,
# all functions in this package should assume that:
#
# * The data/ directory does not exist.
# * Templates are not available.
# * Files do not have the correct permissions
# * The database is not up to date

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Constants;
use Bugzilla::Install::Util qw(bin_loc install_string);
use Bugzilla::Util qw(generate_random_password wrap_hard);

use Mojo::JSON qw(encode_json);
use Data::Dumper;
use File::Basename qw(dirname);
use English qw($EGID);
use List::Util qw(first);
use Tie::Hash::NamedCapture;
use Safe;
use Package::Stash;
use Term::ANSIColor;
use Sys::Hostname qw(hostname);

use parent qw(Exporter);

our @EXPORT_OK = qw(
  read_localconfig
  update_localconfig
  LOCALCONFIG_VARS
);

# might want to change this for upstream
use constant ENV_PREFIX => 'BMO_';
use constant PARAM_OVERRIDE =>
  qw( use_mailer_queue mail_delivery_method shadowdb shadowdbhost shadowdbport shadowdbsock );

sub _sensible_group {
  return '' if ON_WINDOWS;
  return scalar getgrgid($EGID);
}

use constant LOCALCONFIG_VARS => (
  {name => 'create_htaccess', default => 1,},
  {name => 'webservergroup',  default => \&_sensible_group,},
  {name => 'use_suexec',      default => 0,},
  {name => 'db_driver',       default => 'mysql',},
  {name => 'db_service',      default => '',},
  {name => 'db_host',         default => 'localhost',},
  {name => 'db_name',         default => 'bugs',},
  {

    name    => 'db_user',
    default => 'bugs',
  },
  {name => 'db_pass',      default => '',},
  {name => 'db_port',      default => 0,},
  {name => 'db_sock',      default => '',},
  {name => 'db_check',     default => 1,},
  {name => 'db_mysql_ssl_ca_file',     default => '',},
  {name => 'db_mysql_ssl_ca_path',     default => '',},
  {name => 'db_mysql_ssl_client_cert', default => '',},
  {name => 'db_mysql_ssl_client_key',  default => '',},
  {name => 'db_mysql_ssl_get_pubkey',  default => 0,},
  {name => 'index_html',   default => 0,},
  {name => 'cvsbin',       default => sub { bin_loc('cvs') },},
  {name => 'interdiffbin', default => sub { bin_loc('interdiff') },},
  {name => 'diffpath',     default => sub { dirname(bin_loc('diff')) },},
  {
    name => 'site_wide_secret',

    # 64 characters is roughly the equivalent of a 384-bit key, which
    # is larger than anybody would ever be able to brute-force.
    default => sub { generate_random_password(64) },
  },
  {name => 'jwt_secret', default => sub { generate_random_password(64) },},
  {
    name    => 'param_override',
    default => {
      use_mailer_queue     => undef,
      mail_delivery_method => undef,
      shadowdb             => undef,
      shadowdbhost         => undef,
      shadowdbport         => undef,
      shadowdbsock         => undef,
    },
  },
  {name => 'setrlimit',           default => encode_json({RLIMIT_AS => 2e9}),},
  {name => 'size_limit',          default => 750000,},
  {name => 'memcached_servers',   default => '',},
  {name => 'memcached_namespace', default => "bugzilla:",},
  {name => 'urlbase',             default => '',},
  {name => 'canonical_urlbase',   lazy => 1},
  {name => 'logging_method',      default => 'syslog'},
  {name => 'nobody_user',         default => 'nobody@mozilla.org'},
  {name => 'attachment_base',     default => '',},
  {name => 'ses_username',        default => '',},
  {name => 'ses_password',        default => '',},
  {name => 'inbound_proxies',     default => '',},
  {name => 'shadowdb_user',       default => '',},
  {name => 'shadowdb_pass',       default => '',},
  {name => 'datadog_host',        default => '',},
  {name => 'datadog_port',        default => 8125,},
);

sub _read_localconfig_from_env {
  my %localconfig;

  foreach my $var (LOCALCONFIG_VARS) {
    my $name = $var->{name};
    my $key  = ENV_PREFIX . $name;
    if ($name eq 'param_override') {
      foreach my $override (PARAM_OVERRIDE) {
        my $o_key = ENV_PREFIX . $override;
        $localconfig{param_override}{$override} = $ENV{$o_key};
      }
    }
    elsif (exists $ENV{$key}) {
      $localconfig{$name} = $ENV{$key};
    }
    else {
      my $default = $var->{default};
      $localconfig{$name} = ref($default) eq 'CODE' ? $default->() : $default;
    }
  }

  return \%localconfig;
}

sub _read_localconfig_from_file {
  my ($include_deprecated) = @_;
  my $filename = bz_locations()->{'localconfig'};

  my %localconfig;
  if (-e $filename) {
    my $s = Safe->new;
    my $stash = Package::Stash->new($s->root);

    # Some people like to store their database password in another file.
    $s->permit('dofile');

    $s->rdo($filename);
    if ($@ || $!) {
      my $err_msg = $@ ? $@ : $!;
      die install_string(
        'error_localconfig_read', {error => $err_msg, localconfig => $filename}
        ),
        "\n";
    }

    my @read_symbols;
    if ($include_deprecated) {
      # And now we read the contents of every var in the symbol table.
      # However:
      # * We only include symbols that start with an alphanumeric
      #   character. This excludes symbols like "_<./localconfig"
      #   that show up in some perls.
      # * We ignore the INC symbol, which exists in every package.
      # * Perl 5.10 includes default symbol tables which
      #   contain "::", and we want to ignore those.
      @read_symbols
        = grep { /^[A-Za-z0-1]/ and !/^INC$/ and !/::/ } $stash->list_all_symbols();
    }
    else {
      @read_symbols = map($_->{name}, LOCALCONFIG_VARS);
    }
    foreach my $var (@read_symbols) {
      # We don't know the type of any setting.
      # So we figure out its type by trying first a scalar, then an array, then a hash.

      foreach my $sigil (qw( $ @ % )) {
        my $symbol = $sigil . $var;
        if ($stash->has_symbol($symbol)) {
          my $val = $stash->get_symbol($symbol);
          $localconfig{$var} = ref($val) eq 'SCALAR' ? $$val : $val;
        }
      }
    }
  }

  return \%localconfig;
}

sub read_localconfig {
  my ($include_deprecated) = @_;
  my $config
    = $ENV{LOCALCONFIG_ENV}
    ? _read_localconfig_from_env()
    : _read_localconfig_from_file($include_deprecated);

  return $config;
}

#
# This is quite tricky. But fun!
#
# First we read the file 'localconfig'. Then we check if the variables we
# need are defined. If not, we will append the new settings to
# localconfig, instruct the user to check them, and stop.
#
# Why do it this way?
#
# Assume we will enhance Bugzilla and eventually more local configuration
# stuff arises on the horizon.
#
# But the file 'localconfig' is not in the Bugzilla CVS or tarfile. You
# know, we never want to overwrite your own version of 'localconfig', so
# we can't put it into the CVS/tarfile, can we?
#
# Now, when we need a new variable, we simply add the necessary stuff to
# LOCALCONFIG_VARS. When the user gets the new version of Bugzilla from CVS and
# runs checksetup, it finds out "Oh, there is something new". Then it adds
# some default value to the user's local setup and informs the user to
# check that to see if it is what the user wants.
#
# Cute, ey?
#
sub update_localconfig {
  my ($params) = @_;

  if ($ENV{LOCALCONFIG_ENV}) {
    require Carp;
    Carp::croak("update_localconfig() called with LOCALCONFIG_ENV enabled");
  }

  my $output      = $params->{output} || 0;
  my $answer      = Bugzilla->installation_answers;
  my $localconfig = read_localconfig('include deprecated');

  my @new_vars;
  foreach my $var (LOCALCONFIG_VARS) {
    my $name  = $var->{name};
    my $value = $localconfig->{$name};

    # Regenerate site_wide_secret if it was made by our old, weak
    # generate_random_password. Previously we used to generate
    # a 256-character string for site_wide_secret.
    $value = undef
      if ($name eq 'site_wide_secret' and defined $value and length($value) == 256);

    if (!defined $value) {
      push(@new_vars, $name);
      $var->{default} = &{$var->{default}} if ref($var->{default}) eq 'CODE';
      if (exists $answer->{$name}) {
        $localconfig->{$name} = $answer->{$name};
      }
      else {
        $localconfig->{$name} = $var->{default};
      }
    }
  }

  if (!$localconfig->{interdiffbin} && $output) {
    print "\n", install_string('patchutils_missing'), "\n";
  }

  my @old_vars;
  foreach my $var (keys %$localconfig) {
    push(@old_vars, $var) if !grep($_->{name} eq $var, LOCALCONFIG_VARS);
  }

  my $filename = bz_locations->{'localconfig'};

  # Ensure output is sorted and deterministic
  local $Data::Dumper::Sortkeys = 1;

  # Move any custom or old variables into a separate file.
  if (scalar @old_vars) {
    my $filename_old = "$filename.old";
    open(my $old_file, ">>:utf8", $filename_old) or die "$filename_old: $!";
    local $Data::Dumper::Purity = 1;
    foreach my $var (@old_vars) {
      print $old_file Data::Dumper->Dump([$localconfig->{$var}], ["*$var"]) . "\n\n";
    }
    close $old_file;
    my $oldstuff = join(', ', @old_vars);
    print install_string('lc_old_vars',
      {localconfig => $filename, old_file => $filename_old, vars => $oldstuff}),
      "\n";
  }

  # Re-write localconfig
  open(my $fh, ">:utf8", $filename) or die "$filename: $!";
  foreach my $var (LOCALCONFIG_VARS) {
    my $name = $var->{name};
    my $desc = install_string("localconfig_$name", {root => ROOT_USER});
    chomp($desc);

    # Make the description into a comment.
    $desc =~ s/^/# /mg;
    print $fh $desc, "\n", Data::Dumper->Dump([$localconfig->{$name}], ["*$name"]),
      "\n";
  }

  if (@new_vars) {
    my $newstuff = join(', ', @new_vars);
    print "\n";
    print colored(
      install_string(
        'lc_new_vars', {localconfig => $filename, new_vars => wrap_hard($newstuff, 70)}
      ),
      COLOR_ERROR
      ),
      "\n";
    exit unless $params->{use_defaults};
  }

  # Reset the cache for Bugzilla->localconfig so that it will be re-read
  delete Bugzilla->process_cache->{localconfig};

  return {old_vars => \@old_vars, new_vars => \@new_vars};
}

1;

__END__

=head1 NAME

Bugzilla::Install::Localconfig - Functions and variables dealing
  with the manipulation and creation of the F<localconfig> file.

=head1 SYNOPSIS

 use Bugzilla::Install::Requirements qw(update_localconfig);
 update_localconfig({ output => 1 });

=head1 DESCRIPTION

This module is used primarily by L<checksetup.pl> to create and
modify the localconfig file. Most scripts should use L<Bugzilla/localconfig>
to access localconfig variables.

=head1 CONSTANTS

=over

=item C<LOCALCONFIG_VARS>

An array of hashrefs. These hashrefs contain three keys:

 name    - The name of the variable.
 default - The default value for the variable. Should always be
           something that can fit in a scalar.
 desc    - Additional text to put in localconfig before the variable
           definition. Must end in a newline. Each line should start
           with "#" unless you have some REALLY good reason not
           to do that.

=item C<OLD_LOCALCONFIG_VARS>

An array of names of variables. If C<update_localconfig> finds these
variables defined in localconfig, it will print out a warning.

=back

=head1 SUBROUTINES

=over

=item C<read_localconfig>

=over

=item B<Description>

Reads the localconfig file and returns all valid values in a hashref.

=item B<Params>

=over

=item C<$include_deprecated>

C<true> if you want the returned hashref to include *any* variable
currently defined in localconfig, even if it doesn't exist in
C<LOCALCONFIG_VARS>. Generally this is is only for use
by L</update_localconfig>.

=back

=item B<Returns>

A hashref of the localconfig variables. If an array is defined in
localconfig, it will be an arrayref in the returned hash. If a
hash is defined, it will be a hashref in the returned hash.
Only includes variables specified in C<LOCALCONFIG_VARS>, unless
C<$include_deprecated> is true.

=back


=item C<update_localconfig>

Description: Adds any new variables to localconfig that aren't
             currently defined there. Also optionally prints out
             a message about vars that *should* be there and aren't.
             Exits the program if it adds any new vars.

Params:      C<$output> - C<true> if the function should display informational
                 output and warnings. It will always display errors or
                 any message which would cause program execution to halt.

Returns:     A hashref, with C<old_vals> being an array of names of variables
             that were removed, and C<new_vals> being an array of names
             of variables that were added to localconfig.

=back
