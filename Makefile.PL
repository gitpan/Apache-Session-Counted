use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
	      'NAME'	=> 'Apache::Session::Counted',
	      'VERSION_FROM' => 'Counted.pm', # finds $VERSION
	      dist => {
		       PREOP => 'co -l README && pod2text Counted.pm > README && ci -u README',
		      }
);

sub MY::test {
  my($self)=@_;
  qq{test:\n\t$self->{NOECHO}echo No automated tests available.
};
}
