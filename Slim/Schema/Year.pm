package Slim::Schema::Year;

# $Id$

use strict;
use base 'Slim::Schema::DBI';

use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

{
	my $class = __PACKAGE__;

	# Magic to create a ResultSource for this inherited class.
	$class->table('years');

	$class->add_columns('id');
	$class->set_primary_key('id');

	$class->has_many('albums' => 'Slim::Schema::Album' => 'year');
	$class->has_many('tracks' => 'Slim::Schema::Track' => 'year');

	$class->resultset_class('Slim::Schema::ResultSet::Year');
}

# For saving favorites
sub url {
	my $self = shift;

	return Slim::Utils::Misc::escape(sprintf('db:year.id=%s', $self->id));
}

sub name {
	my $self = shift;

	return $self->id || string('UNK');
}

sub namesort {
	my $self = shift;

	return $self->name;
}

sub displayAsHTML {
	my ($self, $form, $descend, $sort) = @_;

	$form->{'text'} = $self->name;
}

1;

__END__
