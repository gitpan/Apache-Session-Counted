package Apache::Session::Counted;
use Apache::Session::Serialize::Storable;

use strict;
use vars qw(@ISA);
@ISA = qw(Apache::Session);
use vars qw($VERSION);
$VERSION = sprintf "%d.%02d", q$Revision: 1.10 $ =~ /(\d+)\.(\d+)/;

use Apache::Session;
use File::CounterFile;

{
  package Apache::Session::CountedStore;
  use Symbol qw(gensym);

  use strict;

  sub new { bless {}, shift }

  # write. Note that we alias insert and update
  sub update {
    my $self    = shift;
    my $session = shift;
    my $storefile = $self->storefilename($session);
    my $fh = gensym;
    open $fh, ">$storefile\0" or
      die "Could not open file $storefile for writing: $!
Maybe you haven't initialized the storage directory with
use Apache::Session::Counted;
Apache::Session::CountedStore->tree_init(\$dir,\$levels)";
    print $fh $session->{serialized}; # $fh->print might fail in some perls
    close $fh;
  }
  *insert = \&update;

  # retrieve
  sub materialize {
    my $self    = shift;
    my $session = shift;
    my $storefile = $self->storefilename($session);
    my $fh = gensym;
    open $fh, "<$storefile\0" or
        die "Could not open file $storefile for reading: $!";
    local $/;
    $session->{serialized} = <$fh>;
    close $fh or die $!;
  }

  sub remove {
    my $self    = shift;
    my $session = shift;
    my $storefile = $self->storefilename($session);
    unlink $storefile or
        warn "Object $storefile does not exist in the data store";
  }

  sub tree_init {
    my $self    = shift;
    my $dir = shift;
    my $levels = shift;
    my $n = 0x100 ** $levels;
    warn "Creating directory $dir and $n subdirectories in $levels level(s)\n";
    warn "This may take a while\n" if $levels>1;
    require File::Path;
    $|=1;
    my $feedback =
        sub {
          $n--;
          printf "\r$n directories left             " unless $n % 256;
          print "\n" unless $n;
        };
    File::Path::mkpath($dir);
    make_dirs($dir,$levels,$feedback); # function for speed
  }

  sub make_dirs {
    my($dir, $levels, $feedback) = @_;
    $levels--;
    for (my $i=0; $i<256; $i++) {
      my $subdir = sprintf "%s/%02x", $dir, $i;
      -d $subdir or mkdir $subdir, 0755 or die "Couldn't mkdir $subdir: $!";
      $feedback->();
      make_dirs($subdir, $levels, $feedback) if $levels;
    }
  }

  sub storefilename {
    my $self    = shift;
    my $session = shift;
    die "The argument 'Directory' for object storage must be passed as an argument"
       unless defined $session->{args}{Directory};
    my $dir = $session->{args}{Directory};
    my $levels = $session->{args}{DirLevels} || 0;
    # here we depart from TreeStore:
    my($file) = $session->{data}{_session_id} =~ /^([\da-f]+)/;
    die "Too short ID part '$file' in session ID'" if length($file)<8;
    while ($levels) {
      $file =~ s|((..){$levels})|$1/|;
      $levels--;
    }
    "$dir/$file";
  }
}

# Counted is locked by definition
sub release_all_locks {
  return;
}

*get_lock_manager = \&release_all_locks;
*release_read_lock = \&release_all_locks;
*release_write_lock = \&release_all_locks;
*acquire_read_lock = \&release_all_locks;
*acquire_write_lock = \&release_all_locks;

sub TIEHASH {
  my $class = shift;

  my $session_id = shift;
  my $args       = shift || {};

  # Make sure that the arguments to tie make sense
  # No. Don't Waste Time.
  # $class->validate_id($session_id);
  # if(ref $args ne "HASH") {
  #   die "Additional arguments should be in the form of a hash reference";
  # }

  #Set-up the data structure and make it an object
  #of our class

  my $self = {
              args         => $args,

              data         => { _session_id => $session_id },
              # we always *have* read and write lock and need not care
              lock         => Apache::Session::READ_LOCK|Apache::Session::WRITE_LOCK,
              status       => 0,
              lock_manager => undef,
              generate     => undef,
              serialize    => \&Apache::Session::Serialize::Storable::serialize,
              unserialize  => \&Apache::Session::Serialize::Storable::unserialize,
            };

  bless $self, $class;
  $self->{object_store} = Apache::Session::CountedStore->new($self);

  #If a session ID was passed in, this is an old hash.
  #If not, it is a fresh one.

  if (defined $session_id) {
    $self->make_old;
    $self->restore;
    if ($session_id eq $self->{data}->{_session_id}) {
      # Fine. Validated. Kind of authenticated.
      # ready for a new session ID, keeping state otherwise.
      $self->make_modified if $self->{args}{AlwaysSave};
    } else {
      # oops, somebody else tried this ID, don't show him data.
      delete $self->{data};
      $self->make_new;
    }
  }
  $self->{data}->{_session_id} = $self->generate_id();
  # no make_new here, session-ID doesn't count as data

  return $self;
}

sub generate_id {
  my $self = shift;
  # wants counterfile
  my $cf = $self->{args}{CounterFile} or
      die "Argument CounterFile needed in the attribute hash to the tie";
  my $c;
  eval { $c = File::CounterFile->new($cf,"0"); };
  if ($@) {
    warn "CounterFile problem. Retrying after removing $cf.";
    unlink $cf; # May fail. stupid enough that we are here.
    $c = File::CounterFile->new($cf,"0");
  }
  my $rhexid = sprintf "%08x", $c->inc;
  my $hexid = scalar reverse $rhexid; # optimized for treestore. Not
                                      # everything in one directory

  # we have entropy as bad as rand(). Typically not very good.
  my $password = sprintf "%08x%08x", rand(0xffffffff), rand(0xffffffff);

  $hexid . "_" . $password;
}

1;

=head1 NAME

Apache::Session::Counted - Session management via a File::CounterFile

=head1 SYNOPSIS

 tie %s, 'Apache::Session::Counted', $sessionid, {
                                Directory => <root of directory tree>,
                                DirLevels => <number of dirlevels>,
                                CounterFile => <filename for File::CounterFile>,
                                AlwaysSave => <boolean>
                                                 }

=head1 ALPHA CODE ALERT

This module is a proof of concept, not a final implementaion. There
was very little interest in this module, so it is unlikely that I will
invest much more work. If you find it useful and are interested in
further development, please contact me personally, so we can talk
about future development.

=head1 DESCRIPTION

This session module is based on Apache::Session, but it persues a
different notion of a session, so you probably have to adjust your
expectations a little.

A session in this module only lasts from one request to the next. At
that point a new session starts. Data are not lost though, the only
thing that is lost from one request to the next is the session-ID. So
the only things you have to treat differently than in Apache::Session
are those parts that rely on the session-ID as a fixed token per user.
Everything else remains the same. See below for a discussion what this
model buys you.

The usage of the module is via a tie as described in the synopsis. The
arguments have the following meaning:

=over

=item Directory, DirLevels

Works similar to filestore but as most file systems are slow on large
directories, works in a tree of subdirectories.

=item CounterFile

A filename to be used by the File::CounterFile module. By changing
that file or the filename periodically, you can achieve arbitrary
patterns of key generation.

=item AlwaysSave

A boolean which, if true, forces storing of session data in any case.
If false, only a STORE, DELETE or CLEAR trigger that the session file
will be written when the tied hash goes out of scope. This has the
advantage that you can retrieve an old session without storing its
state again.

=back

=head2 What this model buys you

=over

=item storing state selectively

You need not store session data for each and every request of a
particular user. There are so many CGI requests that can easily be
handled with two hidden fields and do not need any session support on
the server side, and there are others where you definitely need
session support. Both can appear within the same application.
Apache::Session::Counted allows you to switch session writing on and
off during your application without effort. (In fact, this advantage
is shared with the clean persistence model of Apache::Session)

=item keeping track of transactions

As each request of a single user remains stored until you restart the
counter, there are all previous states of a single session close at
hand. The user presses the back button 5 times and changes a decision
and simply opens a new branch of the same session. This can be an
advantage and a disadvantage. I tend to see it as a very strong
feature. Your milage may vary.

=item counter

You get a counter for free which you can control just like
File::CounterFile (because it B<is> File::CounterFile).

=item cleanup

Your data storage area cleans up itself automatically. Whenever you
reset your counter via File::CounterFile, the storage area in use is
being reused. Old files are being overwritten in the same order they
were written, giving you a lot of flexibility to control session
storage time and session storage disk space.

=item performance

The notion of daisy-chained sessions simplifies the code of the
session handler itself quite a bit and it is likely that this
simplification results in an improved performance (not tested yet due
to lack of benchmarking apps for sessions). There are less file stats
and less sections that need locking, but without real world figures,
it's hard to tell what's up.

=back

As with other modules in the Apache::Session collection, the tied hash
contains a key <_session_id>. You must be aware that the value of this
hash entry is not the same as the one you passed in when you retrieved
the session (if you retrieved a session at all). So you have to make
sure that you send your users a new session-id in each response, and
that this is never the old one.

As an implemenation detail it may be of interest to you, that the
session ID in Apache::Session::Counted consists of two or three parts:
an ordinary number which is a simple counter and a session-ID like the
one in Apache::Session. The two parts are concatenated by an
underscore. The first part is used as an identifier of the session and
the second part is used as a password. The first part is easily
predictable, but the second part is as unpredictable as
Apache::Session's session ID. We use the first part for implementation
details like storage on the disk and the second part to verify the
ownership of that token. There may be soon available support for a
third part. That which codes an alias for the machine that actually
has stored the data--may be useful in clusters.

=head1 PREREQUISITES

Apache::Session::Counted needs Apache::Session,
Apache::Session::TreeStore, and File::CounterFile, all available from the CPAN.

=head1 EXAMPLES

XXX Two examples should show the usage of a date string and the usage
of an external cronjob to influence counter and cleanup.

=head1 AUTHOR

Andreas Koenig <andreas.koenig@anima.de>

=head1 COPYRIGHT

This software is copyright(c) 1999 Andreas Koenig. It is free software
and can be used under the same terms as perl, i.e. either the GNU
Public Licence or the Artistic License.

=cut

