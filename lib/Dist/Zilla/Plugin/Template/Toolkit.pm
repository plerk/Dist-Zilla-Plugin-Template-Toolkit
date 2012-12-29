package Dist::Zilla::Plugin::Template::Toolkit;

use Moose;
use v5.10;
use Template;
use Dist::Zilla::File::InMemory;
use List::Util qw(first);

# ABSTRACT: process template files in your dist using Template Toolkit
# VERSION

=head1 SYNOPSIS

 [Template::Toolkit]

=head1 DESCRIPTION

This is a fork of L<Dist::Zilla::Plugin::Template::Tiny> which uses 
L<Template> instead of L<Template::Tiny>.

This plugin processes TT template files included in your distribution using
L<Template>.  It provides a single variable C<dzil> which is an instance of 
L<Dist::Zilla> which can be queried for things like the version or name of 
the distribution.

=cut

with 'Dist::Zilla::Role::FileGatherer';
with 'Dist::Zilla::Role::FileMunger';
with 'Dist::Zilla::Role::FileInjector';
with 'Dist::Zilla::Role::FilePruner';

use namespace::autoclean;

has _template_options => (
  is       => 'ro',
  isa      => 'HashRef',
  required => 1,
);

sub BUILDARGS
{
  my ($class, @arg) = @_;
  my %opt = ref $arg[0] ? %{$arg[0]} : @arg;
  
  # extract the options that are all caps and put them in _template_options
  $opt{_template_options} = { map { $_ => delete $opt{$_} } grep /^[A-Z_]+$/, keys %opt };
  
  $opt{_template_options}->{TRIM} = delete $opt{TRIM}
    if defined $opt{TRIM} && ! defined $opt{_template_options}->{TRIM};
  
  return \%opt;
}

=head1 ATTRIBUTES

=head2 finder

Specifies a L<FileFinder|Dist::Zilla::Role::FileFinder> for the TT files that
you want processed.  If not specified all TT files with the .tt extension will
be processed.

 [FileFinder::ByName / TTFiles]
 file = *.tt
 [Template]
 finder = TTFiles

=cut

has finder => (
  is  => 'ro',
  isa => 'Str',
);

=head2 output_regex

Regular expression substitution used to generate the output filenames.  By default
this is

 [Template]
 output_regex = /\.tt$//

which generates a C<Foo.pm> for each C<Foo.pm.tt>.

=cut

has output_regex => (
  is      => 'ro',
  isa     => 'Str',
  default => '/\.tt$//',
);

=head2 trim

Passed as C<TRIM> to the constructor for L<Template>.  Included for compatability
with L<Dist::Zilla::Plugin::Template::Tiny>, but it is better to use C<TRIM> instead.

=head2 var

Specify additional variables for use by your template.  The format is I<name> = I<value>
so to specify foo = 1 and bar = 'hello world' you would include this in your dist.ini:

 [Template]
 var = foo = 1
 var = bar = hello world

=cut

has var => (
  is      => 'ro',
  isa     => 'ArrayRef[Str]',
  default => sub { [] },
);

=head2 replace

If set to a true value, existing files in the source tree will be replaced, if necessary.

=cut

has replace => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

has _munge_list => (
  is      => 'ro',
  isa     => 'ArrayRef[Dist::Zilla::Role::File]',
  default => sub { [] },
);

has _tt => (
  is      => 'ro',
  isa     => 'Template',
  lazy    => 1,
  default => sub {
    Template->new( shift->_template_options );
  },
);

=head2 prune

If set to a true value, the original template files will NOT be included in the built distribution.

=cut

has prune => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

has _prune_list => (
  is      => 'ro',
  isa     => 'ArrayRef[Dist::Zilla::Role::File]',
  default => sub { [] },
);

=head2 Template options

Any attributes which are in C<ALL CAPS> will be passed directly
into the constructor of L<Template> (see its documentation for
details).  example:

 [Template::Toolkit]
 INCLUDE_PATH = /search/path
 INTERPOLATE  = 1
 POST_CHOMP   = 1
 PRE_PROCESS  = header
 EVAL_PERL    = 1

=cut



=head1 METHODS

=head2 $plugin-E<gt>gather_files( $arg )

This method processes the TT files and injects the results into your dist.

=cut

sub gather_files
{
  my($self, $arg) = @_;

  my $list =
    defined $self->finder 
    ? $self->zilla->find_files($self->finder)
    : [ grep { $_->name =~ /\.tt$/ } @{ $self->zilla->files } ];
    
  foreach my $template (@$list)
  {
    my $filename = do {
      my $filename = $template->name;
      eval q{ $filename =~ s} . $self->output_regex;
      $self->log("processing " . $template->name . " => $filename");
      $filename;
    };
    my $exists = first { $_->name eq $filename } @{ $self->zilla->files };
    if($self->replace && $exists)
    {
      push @{ $self->_munge_list }, [ $template, $exists ];
    }
    else
    {
      my $file = Dist::Zilla::File::InMemory->new(
        name    => $filename,
        content => do {
          my $output = '';
          my $input = $template->content;
          $self->_tt->process(\$input, $self->_vars, \$output);
          $output;
        },
      );
      $self->add_file($file);
    }
    push @{ $self->_prune_list }, $template if $self->prune;
  }
}

sub _vars
{
  my($self) = @_;
  
  unless(defined $self->{_vars})
  {
  
    my %vars = ( dzil => $self->zilla );
    foreach my $var (@{ $self->var })
    {
      if($var =~ /^(.*?)=(.*)$/)
      {
        my $name = $1;
        my $value = $2;
        for($name,$value) {
          s/^\s+//;
          s/\s+$//;
        }
        $vars{$name} = $value;
      }
    }
    
    $self->{_vars} = \%vars;
  }
  
  return $self->{_vars};
}

=head2 $plugin-E<gt>munge_files

This method is used to munge files that need to be replaced instead of injected.

=cut

sub munge_files
{
  my($self) = @_;
  foreach my $item (@{ $self->_munge_list })
  {
    my($template,$file) = @$item;
    my $output = '';
    my $input = $template->content;
    $self->_tt->process(\$input, $self->_vars, \$output) || die $self->_tt->error();
    $file->content($output);
  }
  $self->prune_files;
}

=head2 $plugin-E<gt>prune_files

This method is used to prune the original templates if the C<prune> attribute is
set.

=cut

sub prune_files
{
  my($self) = @_;
  foreach my $template (@{ $self->_prune_list })
  {
    $self->log("pruning " . $template->name);
    $self->zilla->prune_file($template);
  }
  
  @{ $self->_prune_list } = ();
}

=head2 $plugin-E<gt>mvp_multivalue_args

Returns list of attributes that can be specified multiple times.

=cut

sub mvp_multivalue_args { qw( var opt ) }

__PACKAGE__->meta->make_immutable;

1;

=head1 EXAMPLES

Why would you even need templates that get processed when you build your distribution
anyway?  There are many useful L<Dist::Zilla> plugins that provide mechanisms for
manipulating POD and Perl after all.  I work on Perl distributions that are web apps
that include CSS and JavaScript, and I needed a way to get the distribution version into
the JavaScript.  This seemed to be the clearest and most simple way to go about this.

First of all, I have a share directory called public that gets installed via 
L<[ShareDir]|Dist::Zilla::Plugin::ShareDir>.

 [ShareDir]
 dir = public

Next I use this plugin to process .js.tt files in the appropriate directory, so that
.js files are produced.

 [FileFinder::ByName / JavaScriptTTFiles]
 dir = public/js
 file = *.js.tt
 [Template]
 finder = JavaScriptTTFiles
 replace = 1
 prune = 1

Finally, I create a version.js.tt file

 if(PlugAuth === undefined) var PlugAuth = {};
 if(PlugAuth === undefined) PlugAuth.UI = {};
 
 PlugAuth.UI.Name = 'PlugAuth WebUI';
 PlugAuth.UI.VERSION = '[% dzil.version %]';

which gets processed and used when the distribution is built and later installed.  I also
create a version.js file in the same directory so that I can use the distribution without
having to build it.

 if(PlugAuth === undefined) var PlugAuth = {};
 if(PlugAuth === undefined) PlugAuth.UI = {};
 
 PlugAuth.UI.Name = 'PlugAuth WebUI';
 PlugAuth.UI.VERSION = 'dev';

Now when I run it out of the checked out distribution I get C<dev> reported as the version
and the actual version reported when I run from an installed copy.

There are probably other use cases and ways to get yourself into trouble.

=cut
