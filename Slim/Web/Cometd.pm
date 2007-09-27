package Slim::Web::Cometd;

# $Id$

# SqueezeCenter Copyright (c) 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

# This class provides an implementation of the Cometd Bayeux protocol
# The primary purpose is for handling Jive connections, but it may also
# be used in the future for real-time updates to the web interface.
#
# Some of this code is thanks to David Davis' cometd-perl implementation.
#
# Current protocol documentation is available at
# http://svn.xantus.org/shortbus/trunk/bayeux/bayeux.html

use strict;

use bytes;
use Digest::SHA1 qw(sha1_hex);
use HTTP::Date;
use JSON::XS qw(to_json from_json);
use Scalar::Util qw(blessed);
use URI::Escape qw(uri_unescape);

use Slim::Control::Request;
use Slim::Web::Cometd::Manager;
use Slim::Web::HTTP;
use Slim::Utils::Log;
use Slim::Utils::Network;
use Slim::Utils::Timers;

my $log = logger('network.cometd');

my $manager = Slim::Web::Cometd::Manager->new;

# requests that we need to unsubscribe from
my %toUnsubscribe = ();

use constant PROTOCOL_VERSION => '1.0';
use constant RETRY_DELAY      => 5000;

sub init {
	Slim::Web::HTTP::addRawFunction( '/cometd', \&handler );
	Slim::Web::HTTP::addCloseHandler( \&closeHandler );
}

sub handler {
	my ( $httpClient, $httpResponse ) = @_;
	
	# make sure we're connected
	if ( !$httpClient->connected ) {
		$log->warn("Aborting, client not connected: $httpClient");
		return;
	}
	
	my $req = $httpResponse->request;
	my $ct	= $req->content_type;
	
	my ( $params, %ops );
	
	if ( $ct && $ct eq 'text/json' ) {
		# POST
		if ( my $content = $req->content ) {
			$ops{message} = $content;
		}
	}
	elsif ( $ct && $ct eq 'application/x-www-form-urlencoded' ) {
		# POST or GET
		if ( my $content = $req->content ) {
			$params = $content;
		}
		elsif ( $req->uri =~ m{\?message=} ) {
			$params = ( $req->uri =~ m{\?(.*)} )[ 0 ];
		}
	}
	
	if ( $params && $params =~ m{=} ) {
		# uri param ?message=[json]
		%ops = map {
			my ( $k, $v ) = split( '=' );
			uri_unescape( $k ) => uri_unescape( $v )
		} split( '&', $params );
	}
	elsif ( $params ) {
		# uri param ?[json]
		$ops{message} = $params;
	}
	
	if ( !$ops{message} ) {
		sendResponse( 
			$httpClient,
			$httpResponse,
			[ { successful => JSON::XS::false, error => 'no bayeux message found' } ]
		);
		return;
	}

	my $objs = eval { from_json( $ops{message} ) };
	if ( $@ ) {
		sendResponse( 
			$httpClient,
			$httpResponse,
			[ { successful => JSON::XS::false, error => "$@" } ]
		);
		return;
	}
	
	if ( ref $objs ne 'ARRAY' ) {
		if ( $log->is_warn ) {
			$log->warn( 'Got Cometd request that is not an array: ' . Data::Dump::dump($objs) );
		}
		
		sendResponse( 
			$httpClient,
			$httpResponse,
			[ { successful => JSON::XS::false, error => 'bayeux message not an array' } ]
		);
		return;
	}
	
	if ( $log->is_debug ) {
		$log->debug( "Cometd request: " . Data::Dump::dump( $objs ) );
	}
	
	my $clid;
	my $events = [];
	my @errors;
	
	for my $obj ( @{$objs} ) {		
		if ( ref $obj ne 'HASH' ) {
			sendResponse( 
				$httpClient,
				$httpResponse,
				[ { successful => JSON::XS::false, error => 'bayeux event not a hash' } ]
			);
			return;
		}
		
		if ( !$clid ) {
			# specified clientId
			if ( $obj->{clientId} ) {
				$clid = $obj->{clientId};
			}
			elsif ( $obj->{channel} eq '/meta/handshake' ) {
				$clid = new_uuid();
				$manager->add_client( $clid );
			}
			else {
				# No clientId, this is OK for sending unconnected requests
			}
			
			# Register client with HTTP connection
			if ( $clid ) {
				$httpClient->clid( $clid );
			}
		}
		
		last if @errors;
		
		if ( $obj->{channel} eq '/meta/handshake' ) {

			push @{$events}, {
				channel					 => '/meta/handshake',
				version					 => PROTOCOL_VERSION,
				supportedConnectionTypes => [ 'long-polling', 'streaming' ],
				clientId				 => $clid,
				successful				 => JSON::XS::true,
				advice					 => {
					reconnect => 'retry',     # one of "none", "retry", "handshake"
					interval  => RETRY_DELAY, # retry delay in ms
				},
			};			
		}
		elsif ( $obj->{channel} eq '/meta/connect' ) {
			
			if ( !$manager->is_valid_clid( $clid ) ) {
				# Invalid clientId, send advice to re-handshake
				
				push @{$events}, {
					channel    => '/meta/connect',
					clientId   => undef,
					successful => JSON::XS::false,
					timestamp  => time2str( time() ),
					error      => 'invalid clientId',
					advice     => {
						reconnect => 'handshake',
						interval  => 0,
					}
				};
			}
			else {
				# Valid clientId
				
				push @{$events}, {
					channel    => '/meta/connect',
					clientId   => $clid,
					successful => JSON::XS::true,
					timestamp  => time2str( time() ),
				};
				
				# Add any additional pending events
				push @{$events}, ( $manager->get_pending_events( $clid ) );
				
				if ( $obj->{connectionType} eq 'streaming' ) {
					# Streaming connections use chunked transfer encoding
					$httpResponse->header( 'Transfer-Encoding' => 'chunked' );
				
					# Tell HTTP client our transport
					$httpClient->transport( 'streaming' );
					
					# register this connection with the manager
					$manager->register_connection( $clid, $httpClient, $httpResponse );
				}
				else {
					$httpClient->transport( 'polling' );
				}
			}
		}
		elsif ( $obj->{channel} eq '/meta/reconnect' ) {
			
			if ( !$manager->is_valid_clid( $clid ) ) {
				# Invalid clientId, send advice to re-handshake
				
				push @{$events}, {
					channel    => '/meta/reconnect',
					successful => JSON::XS::false,
					timestamp  => time2str( time() ),
					error      => 'invalid clientId',
					advice     => {
						reconnect => 'handshake',
						interval  => 0,
					}
				};
			}
			else {
				# Valid clientId, reconnect them
				
				$log->debug( "Client reconnected: $clid" );
				
				push @{$events}, {
					channel    => '/meta/reconnect',
					successful => JSON::XS::true,
					timestamp  => time2str( time() ),
				};
				
				# Remove disconnect timer
				Slim::Utils::Timers::killTimers( $clid, \&disconnectClient );
				
				# Add any additional pending events
				push @{$events}, ( $manager->get_pending_events( $clid ) );
				
				if ( $obj->{connectionType} eq 'streaming' ) {
					# Streaming connections use chunked transfer encoding
					$httpResponse->header( 'Transfer-Encoding' => 'chunked' );
				
					# Tell HTTP client our transport
					$httpClient->transport( 'streaming' );
					
					# Tell the manager about the new connection
					$manager->register_connection( $clid, $httpClient, $httpResponse );
				}
				else {
					$httpClient->transport( 'polling' );
				}
			}	
		}
		elsif ( $obj->{channel} eq '/meta/disconnect' ) {
			
			if ( !$manager->is_valid_clid( $clid ) ) {
				# Invalid clientId, send error
				
				push @{$events}, {
					channel    => '/meta/disconnect',
					clientId   => undef,
					successful => JSON::XS::false,
					error      => 'invalid clientId',
				};
			}
			else {
				# Valid clientId, disconnect them
				
				push @{$events}, {
					channel    => '/meta/disconnect',
					clientId   => $clid,
					successful => JSON::XS::true,
					timestamp  => time2str( time() ),
				};
				
				# Close the connection after this response
				$httpResponse->header( Connection => 'close' );
			
				disconnectClient( $clid );
			}
		}
		elsif ( $obj->{channel} eq '/meta/subscribe' ) {
			
			if ( !$manager->is_valid_clid( $clid ) ) {
				# Invalid clientId, send advice to re-handshake
				
				push @{$events}, {
					channel    => '/meta/subscribe',
					clientId   => undef,
					successful => JSON::XS::false,
					timestamp  => time2str( time() ),
					error      => 'invalid clientId',
					advice     => {
						reconnect => 'handshake',
						interval  => 0,
					}
				};
			}
			else {
				my $subscriptions = $obj->{subscription};
			
				# a channel name or a channel pattern or an array of channel names and channel patterns.
				if ( !ref $subscriptions ) {
					$subscriptions = [ $subscriptions ];
				}
			
				$manager->add_channels( $clid, $subscriptions );
			
				for my $sub ( @{$subscriptions} ) {
					push @{$events}, {
						channel      => '/meta/subscribe',
						clientId     => $clid,
						successful   => JSON::XS::true,
						subscription => $sub,
					};
				}
			}
		}
		elsif ( $obj->{channel} eq '/meta/unsubscribe' ) {
			
			if ( !$manager->is_valid_clid( $clid ) ) {
				# Invalid clientId, send advice to re-handshake
				
				push @{$events}, {
					channel    => '/meta/unsubscribe',
					clientId   => undef,
					successful => JSON::XS::false,
					timestamp  => time2str( time() ),
					error      => 'invalid clientId',
					advice     => {
						reconnect => 'handshake',
						interval  => 0,
					}
				};
			}
			else {
				my $subscriptions = $obj->{subscription};
			
				# a channel name or a channel pattern or an array of channel names and channel patterns.
				if ( !ref $subscriptions ) {
					$subscriptions = [ $subscriptions ];
				}
			
				$manager->remove_channels( $clid, $subscriptions );
			
				for my $sub ( @{$subscriptions} ) {
					push @{$events}, {
						channel      => '/meta/unsubscribe',
						clientId     => $clid,
						subscription => $sub,
						successful   => JSON::XS::true,
					};
				}
			}
		}
		elsif ( $obj->{channel} eq '/slim/subscribe' ) {
			# A request to execute & subscribe to some SlimServer event
			
			# A valid /slim/subscribe message looks like this:
			# {
			#   channel  => '/slim/subscribe',
			#   id       => <unique id>,
			#   data     => {
			#     response => '/slim/serverstatus', # the channel all messages should be sent back on
			#     request  => [ '', [ 'serverstatus', 0, 50, 'subscribe:60' ],
			#     priority => <value>, # optional priority value, is passed-through with the response
			#   }
			
			my $id       = $obj->{id};
			my $request  = $obj->{data}->{request};
			my $response = $obj->{data}->{response};
			my $priority = $obj->{data}->{priority};
			
			if ( $request && $response ) {
				# We expect the clientId to be part of the response channel
				my ($responseClid) = $response =~ m{/([0-9a-f]{8})/};
				
				my $result = handleRequest( {
					id       => $id,
					request  => $request,
					response => $response,
					priority => $priority,
					clid     => $responseClid,
				} );
				
				if ( $result->{error} ) {
					push @errors, [ '/slim/subscribe', $result->{error} ];
				}
				else {
					push @{$events}, {
						channel      => '/slim/subscribe',
						clientId     => $clid,
						successful   => JSON::XS::true,
						id           => $id,
					};
					
					# If the request was not async, tell the manager to deliver the results to all subscribers
					if ( exists $result->{data} ) {
						$manager->deliver_events( $result );
					}
				}
			}
			elsif ( !$request ) {
				push @errors, [ '/slim/subscribe', 'request data key not found' ];
			}
			elsif ( !$response ) {
				push @errors, [ '/slim/subscribe', 'response data key not found' ];
			}
		}
		elsif ( $obj->{channel} eq '/slim/unsubscribe' ) {
			# A request to unsubscribe from a SlimServer event, this is not the same as /meta/unsubscribe
			
			# A valid /slim/unsubscribe message looks like this:
			# {
			#   channel  => '/slim/unsubscribe',
			#   data     => {
			#     unsubscribe => '/slim/serverstatus',
			#   }
			
			my $unsub = $obj->{data}->{unsubscribe};
			
			# Add it to our list of pending unsubscribe events
			# It will be removed the next time we get a requestCallback for it
			$toUnsubscribe{$unsub} = 1;
			
			push @{$events}, {
				channel      => '/slim/unsubscribe',
				clientId     => $clid,
				successful   => JSON::XS::true,
				data         => $obj->{data},
			};
		}
		elsif ( $obj->{channel} eq '/slim/request' ) {
			# A request to execute a one-time SlimServer event
			
			# A valid /slim/request message looks like this:
			# {
			#   channel  => '/slim/request',
			#   id       => <unique id>, (optional)
			#   data     => {
			#     response => '/slim/<clientId>/request',
			#     request  => [ '', [ 'menu', 0, 100, ],
			#     priority => <value>, # optional priority value, is passed-through with the response
			#   }
			
			my $id       = $obj->{id};
			my $request  = $obj->{data}->{request};
			my $response = $obj->{data}->{response};
			my $priority = $obj->{data}->{priority};
			
			if ( $request && $response ) {
				# We expect the clientId to be part of the response channel
				my ($responseClid) = $response =~ m{/([0-9a-f]{8})/};
				
				my $result = handleRequest( {
					id       => $id,
					request  => $request,
					response => $response,
					priority => $priority,
					clid     => $responseClid,
				} );
				
				if ( $result->{error} ) {
					push @errors, [ '/slim/request', $result->{error} ];
				}
				else {
					# If the caller does not want the response, id will be undef
					if ( !$id ) {
						# do nothing
						$log->debug('Not sending response to request, caller does not want it');
					}
					else {
						# This response is optional, but we do it anyway
						push @{$events}, {
							channel    => '/slim/request',
							clientId   => $clid,
							successful => JSON::XS::true,
							id         => $id,
						};
					
						# If the request was not async, tell the manager to deliver the results to all subscribers
						if ( exists $result->{data} ) {
							$manager->deliver_events( $result );
						}
					}
				}
			}
			elsif ( !$request ) {
				push @errors, [ '/slim/request', 'request data key not found' ];
			}
			elsif ( !$response ) {
				push @errors, [ '/slim/request', 'response data key not found' ];
			}
		}
	}
	
	if ( @errors ) {
		my $out = [];
		
		for my $error ( @errors ) {
			push @{$out}, {
				channel    => $error->[0],
				successful => JSON::XS::false,
				error      => $error->[1],
			};
		}
		
		sendResponse(
			$httpClient, $httpResponse, $out,
		);
		
		return;
	}
	
	sendResponse(
		$httpClient, $httpResponse, $events,
	);
}

sub sendResponse {
	my ( $httpClient, $httpResponse, $out ) = @_;
	
	$httpResponse->code( 200 );
	$httpResponse->header( Expires => '-1' );
	$httpResponse->header( Pragma => 'no-cache' );
	$httpResponse->header( 'Cache-Control' => 'no-cache' );
	$httpResponse->header( 'Content-Type' => 'application/json' );
	
	$out = eval { to_json($out) };
	if ( $@ ) {
		$out = to_json( [ { successful => JSON::XS::false, error => "$@" } ] );
	}
	
	my $sendheaders = 1; # should we send headers?
	my $chunked     = 0; # is this a chunked connection?
	
	if ( $httpResponse->header('Transfer-Encoding') ) {
		$chunked = 1;
		
		# Have we already sent headers on this connection?
		if ( $httpClient->sent_headers ) {
			$sendheaders = 0;
		}
		else {
			$httpClient->sent_headers(1);
		}
	}
	else {
		$httpResponse->header( 'Content-Length', length $out );
		$sendheaders = 1;
	}
	
	if ( $log->is_debug ) {
		if ( $sendheaders ) {
			$log->debug( "Sending Cometd Response:\n" 
				. $httpResponse->as_string . $out
			);
		}
		else {
			$log->debug( "Sending Cometd chunk:\n" . $out );
		}
	}
	
	Slim::Web::HTTP::addHTTPResponse(
		$httpClient, $httpResponse, \$out, $sendheaders, $chunked,
	);
}

sub handleRequest {
	my $params = shift;
	
	my $id       = $params->{id};
	my $cmd      = $params->{request};
	my $response = $params->{response};
	my $priority = $params->{priority};
	my $clid     = $params->{clid};
	
	my $args = $cmd->[1];

	if ( !$args || ref $args ne 'ARRAY' ) {
		return { error => 'invalid request arguments, array expected' };
	}
	
	my $clientid;
	
	if ( my $mac = $cmd->[0] ) {
		my $client   = Slim::Player::Client::getClient($mac);
		$clientid = blessed($client) ? $client->id : undef;
	}
	
	# create a request
	my $request = Slim::Control::Request->new( $clientid, $args );
	
	if ( $request->isStatusDispatchable ) {
		# fix the encoding and/or manage charset param
		$request->fixEncoding;
		
		# remember the response channel, request id, and priority
		$request->source( "$response|$id|$priority" );
		
		# Link this request to the IP of the request
		$request->connectionID($clid);
		
		# Only set a callback if the caller wants a response
		if ( $id ) {
			$request->autoExecuteCallback( \&requestCallback );
		}
		
		$request->execute();
		
		if ( $request->isStatusError ) {
			return { error => 'request failed with error: ' . $request->getStatusText };
		}
		
		# If user doesn't care about the response, return nothing
		if ( !$id ) {
			$log->debug( "Request for $response, but caller does not care about the response" );
			
			return { ok => 1 };
		}
		
		# handle async commands
		if ( $request->isStatusProcessing ) {
			# Only set a callback if the caller wants a response
			$request->callbackParameters( \&requestCallback );
			
			$log->debug( "Request for $response / $id is async, will callback" );
			
			return { ok => 1 };
		}
		
		# the request was successful and is not async
		$log->debug( "Request for $response / $id is not async" );
		
		return {
			channel => $response,
			id      => $id,
			data    => $request->getResults,
			ext     => {
				priority => $priority,
			},
		};
	}
	else {
		return { error => 'invalid request: ' . $request->getStatusText };
	}
}

sub requestCallback {
	my $request = shift;
	
	my ($channel, $id, $priority) = split /\|/, $request->source, 3;
	
	$log->debug( "requestCallback got results for $channel / $id" );
	
	# Do we need to unsubscribe from this request?
	if ( exists $toUnsubscribe{$channel} ) {
		$log->debug( "requestCallback: unsubscribing from $channel" );
		
		$request->removeAutoExecuteCallback();
		
		delete $toUnsubscribe{$channel};
		
		return;
	}
	
	# Construct event response
	my $events = [ {
		channel   => $channel,
		id        => $id,
		data      => $request->getResults,
		ext       => {
			priority => $priority,
		},
	} ];
	
	# Deliver request results via Manager
	$manager->deliver_events( $events );
}

sub closeHandler {
	my $httpClient = shift;
	
	# unregister connection from manager
	if ( my $clid = $httpClient->clid ) {
		my $transport = $httpClient->transport;
			
		if ( $log->is_debug ) {
			my $peer = $httpClient->peerhost . ':' . $httpClient->peerport;
			$log->debug( "Lost connection from $peer, clid: $clid, transport: " . ( $transport || 'none' ) );
		}
		
		if ( $transport eq 'streaming' ) {
			$manager->remove_connection( $clid );
			
			Slim::Utils::Timers::setTimer(
				$clid,
				Time::HiRes::time() + ( ( RETRY_DELAY / 1000 ) * 2 ),
				\&disconnectClient,
			);
		}
	}
}

sub disconnectClient {
	my $clid = shift;
	
	# Clean up this client's data
	if ( $manager->is_valid_clid( $clid) ) {
		$log->debug( "Disconnect for $clid, removing subscriptions" );
	
		# Remove any subscriptions for this client, 
		Slim::Control::Request::unregisterAutoExecute( $clid );
			
		$log->debug("Unregistered all auto-execute requests for client $clid");
	
		# Remove client from manager
		$manager->remove_client( $clid );
	}
}

# Create a new UUID
sub new_uuid {
	return substr( sha1_hex( Time::HiRes::time() . $$ . Slim::Utils::Network::hostName() ), 0, 8 );
}

1;
