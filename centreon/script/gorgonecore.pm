# 
# Copyright 2019 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package centreon::script::gorgonecore;

use strict;
use warnings;
use POSIX ":sys_wait_h";
use Sys::Hostname;
use ZMQ::LibZMQ4;
use ZMQ::Constants qw(:all);
use centreon::gorgone::common;
use centreon::misc::db;
use centreon::script;

my ($gorgone, $gorgone_config);

use base qw(centreon::script);

my $VERSION = '1.0';
my %handlers = (TERM => {}, HUP => {}, CHLD => {});

sub new {
    my $class = shift;
    my $self = $class->SUPER::new('gorgoned',
        centreon_db_conn => 0,
        centstorage_db_conn => 0,
        noconfig => 1
    );

    bless $self, $class;
    $self->add_options(
        'config-extra:s' => \$self->{opt_extra},
    );

    $self->{opt_extra} = '';
    $self->{return_child} = {};
    $self->{stop} = 0;
    $self->{internal_register} = {};
    $self->{modules_register} = {};
    $self->{modules_events} = {};
    $self->{modules_id} = {};
    $self->{sessions_timer} = time();
    $self->{kill_timer} = undef;
    
    return $self;
}

sub init {
    my $self = shift;
    $self->SUPER::init();

    # redefine to avoid out when we try modules
    $SIG{__DIE__} = undef;

    ## load config ini
    if (! -f $self->{opt_extra}) {
        $self->{logger}->writeLogError("Can't find extra config file '$self->{opt_extra}'");
        exit(1);
    }
    $gorgone_config = centreon::gorgone::common::read_config(
        config_file => $self->{opt_extra},
        logger => $self->{logger}
    );
    if (defined($gorgone_config->{gorgonecore}{external_com_type}) && $gorgone_config->{gorgonecore}{external_com_type} ne '') {
        centreon::gorgone::common::loadprivkey(logger => $self->{logger}, privkey => $gorgone_config->{gorgonecore}{privkey});
    }
    
    # Database connections:
    #    We add in gorgone database
    $gorgone->{db_gorgone} = centreon::misc::db->new(
        type => $gorgone_config->{gorgonecore}{gorgone_db_type},
        db => $gorgone_config->{gorgonecore}{gorgone_db_name},
        host => $gorgone_config->{gorgonecore}{gorgone_db_host},
        port => $gorgone_config->{gorgonecore}{gorgone_db_port},
        user => $gorgone_config->{gorgonecore}{gorgone_db_user},
        password => $gorgone_config->{gorgonecore}{gorgone_db_password},
        force => 2,
        logger => $gorgone->{logger}
    );
    $gorgone->{db_gorgone}->set_inactive_destroy();
    if ($gorgone->{db_gorgone}->connect() == -1) {
        $gorgone->{logger}->writeLogInfo("Cannot connect. We quit!!");
        exit(1);
    }
    
    $self->{hostname} = $gorgone_config->{gorgonecore}{hostname};
    if (!defined($self->{hostname}) || $self->{hostname} eq '') {
        $self->{hostname} = hostname();
    }
    
    $self->{id} = $gorgone_config->{gorgonecore}{id};
    if (!defined($self->{hostname}) || $self->{hostname} eq '') {
        #$self->{id} = get_poller_id(dbh => $dbh, name => $self->{hostname});
    }
    
    $self->load_modules();
    
    $self->set_signal_handlers();
}

sub set_signal_handlers {
    my $self = shift;

    $SIG{TERM} = \&class_handle_TERM;
    $handlers{TERM}->{$self} = sub { $self->handle_TERM() };
    $SIG{HUP} = \&class_handle_HUP;
    $handlers{HUP}->{$self} = sub { $self->handle_HUP() };
    $SIG{CHLD} = \&class_handle_CHLD;
    $handlers{CHLD}->{$self} = sub { $self->handle_CHLD() };
}

sub class_handle_TERM {
    foreach (keys %{$handlers{TERM}}) {
        &{$handlers{TERM}->{$_}}();
    }
}

sub class_handle_HUP {
    foreach (keys %{$handlers{HUP}}) {
        &{$handlers{HUP}->{$_}}();
    }
}

sub class_handle_CHLD {
    foreach (keys %{$handlers{CHLD}}) {
        &{$handlers{CHLD}->{$_}}();
    }
}

sub handle_TERM {
    my $self = shift;
    $self->{logger}->writeLogInfo("$$ Receiving order to stop...");
    $self->{stop} = 1;
    
    foreach my $name (keys %{$self->{modules_register}}) {
        $self->{modules_register}->{$name}->{gently}->(logger => $self->{logger});
    }
    $self->{kill_timer} = time();
}

sub handle_HUP {
    my $self = shift;
    $self->{logger}->writeLogInfo("$$ Receiving order to reload...");
    # TODO
}

sub handle_CHLD {
    my $self = shift;
    my $child_pid;

    while (($child_pid = waitpid(-1, &WNOHANG)) > 0) {
        $self->{return_child}->{$child_pid} = time();
    }
    
    $SIG{CHLD} = \&class_handle_CHLD;
}

sub load_modules {
    my $self = shift;

    foreach my $section (keys %{$gorgone_config}) {
        next if (!defined($gorgone_config->{$section}{module}));
        
        my $name = $gorgone_config->{$section}{module};
        (my $file = "$name.pm") =~ s{::}{/}g;
        require $file;
        $self->{logger}->writeLogInfo("Module '$section' is loading");
        $self->{modules_register}->{$name} = {};
        
        foreach my $method_name (('register', 'routing', 'kill', 'kill_internal', 'gently', 'check', 'init')) {
            unless ($self->{modules_register}->{$name}->{$method_name} = $name->can($method_name)) {
                $self->{logger}->writeLogError("No function '$method_name' for module '$section'");
                exit(1);
            }
        }

        my ($events, $id) = $self->{modules_register}->{$name}->{register}->(
            config => $gorgone_config->{$section},
            config_core => $gorgone_config->{gorgonecore},
            config_db_centreon => $gorgone_config->{db_centreon},
            config_db_centstorage => $gorgone_config->{db_centstorage}
        );
        $self->{modules_id}->{$id} = $name;
        foreach my $event (@{$events}) {
            $self->{modules_events}->{$event} = [] if (!defined($self->{modules_events}->{$event}));
            push @{$self->{modules_events}->{$event}}, $name;
        }

        $self->{logger}->writeLogInfo("Module '$section' is loaded");
    }    
    
    # Load internal functions
    foreach my $method_name (('putlog', 'getlog', 'kill', 'ping', 'constatus')) {
        unless ($self->{internal_register}->{$method_name} = centreon::gorgone::common->can($method_name)) {
            $self->{logger}->writeLogError("No function '$method_name'");
            exit(1);
        }
    }
}

sub message_run {
    my ($self, %options) = @_;

    if ($options{message} !~ /^\[(.+?)\]\s+\[(.*?)\]\s+\[(.*?)\]\s+(.*)$/) {
        return (undef, 1, { mesage => 'request not well formatted' });
    }
    my ($action, $token, $target, $data) = ($1, $2, $3, $4);
    if ($action !~ /^(PUTLOG|GETLOG|KILL|PING|CONSTATUS)$/ && !defined($self->{modules_events}->{$action})) {
        centreon::gorgone::common::add_history(
            dbh => $self->{db_gorgone},
            code => 1, token => $token,
            data => { msg => "action '$action' is not known" },
            json_encode => 1
        );
        return (undef, 1, { message => "action '$action' is not known" });
    }
    if (!defined($token) || $token eq '') {
        $token = centreon::gorgone::common::generate_token();
    }

    if ($self->{stop} == 1) {
        centreon::gorgone::common::add_history(
            dbh => $self->{db_gorgone},
            code => 1, token => $token,
            data => { msg => 'gorgone is stopping/restarting. Not proceed request.' },
            json_encode => 1
        );
        return ($token, 1, { message => "gorgone is stopping/restarting. Not proceed request." });
    }
    
    # Check Routing
    if (defined($target) && $target ne '') {
        # Check if not myself ;)
        if ($target ne $self->{id}) {
            $self->{modules_register}->{ $self->{modules_id}->{$gorgone_config->{gorgonecore}{proxy_name}}  }->{routing}->(
                socket => $self->{internal_socket}, dbh => $self->{db_gorgone}, logger => $self->{logger}, 
                action => $1, token => $token, target => $target, data => $data,
                hostname => $self->{hostname}
            );
            return ($token, 0);
        }
    }
    
    if ($action =~ /^(PUTLOG|GETLOG|KILL|PING|CONSTATUS)$/) {
        my ($code, $response, $response_type) = $self->{internal_register}->{lc($action)}->(
            gorgone => $self,
            gorgone_config => $gorgone_config,
            id => $self->{id},
            data => $data,
            token => $token,
            logger => $self->{logger}
        );
        return ($token, $code, $response, $response_type);
    } else {
        foreach (@{$self->{modules_events}->{$action}}) {
            $self->{modules_register}->{$_}->{routing}->(
                socket => $self->{internal_socket}, 
                dbh => $self->{db_gorgone}, logger => $self->{logger},
                action => $1, token => $token, target => $target, data => $data,
                hostname => $self->{hostname}
            );
        }
    }
    return ($token, 0);
}

sub router_internal_event {
    while (1) {
        my ($identity, $message) = centreon::gorgone::common::zmq_read_message(socket => $gorgone->{internal_socket});
        my ($token, $code, $response, $response_type) = $gorgone->message_run(message => $message);
        centreon::gorgone::common::zmq_core_response(
            socket => $gorgone->{internal_socket},
            identity => $identity, response_type => $response_type,
            data => $response, code => $code,
            token => $token
        );
        last unless (centreon::gorgone::common::zmq_still_read(socket => $gorgone->{internal_socket}));
    }
}

sub handshake {
    my ($self, %options) = @_;

    my ($identity, $message) = centreon::gorgone::common::zmq_read_message(socket => $self->{external_socket});
    my ($status, $key) = centreon::gorgone::common::is_handshake_done(dbh => $self->{db_gorgone}, identity => $identity);

    if ($status == 1) {
        ($status, my $response) = centreon::gorgone::common::uncrypt_message(
            cipher => $gorgone_config->{gorgonecore}{cipher}, 
            message => $message,
            symkey => $key,
            vector => $gorgone_config->{gorgonecore}{vector}
        );
        if ($status == 0 && $response =~ /^\[.*\]/) {
            centreon::gorgone::common::update_identity(dbh => $self->{db_gorgone}, identity => $identity);
            return ($identity, $key, $response);
        }
        
        # Maybe he want to redo a handshake
        $status = 0;    
    }
    
    if ($status == -1) {
        centreon::gorgone::common::zmq_core_response(
            socket => $self->{external_socket}, 
            identity => $identity,
            code => 1,
            data => { message => 'Database issue' }
        );
        return undef;
    } elsif ($status == 0) {
        # We try to uncrypt
        if (centreon::gorgone::common::is_client_can_connect(message => $message,
                                                               logger => $self->{logger}) == -1) {
            centreon::gorgone::common::zmq_core_response(
                socket => $self->{external_socket}, identity => $identity,
                code => 1, data => { message => 'handshake issue' }
            );
        }
        my ($status, $symkey) = centreon::gorgone::common::generate_symkey(
            logger => $self->{logger},
            cipher => $gorgone_config->{gorgonecore}{cipher},
            keysize => $gorgone_config->{gorgonecore}{keysize}
        );
        if ($status == -1) {
            centreon::gorgone::common::zmq_core_response(
                socket => $self->{external_socket}, identity => $identity,
                code => 1, data => { message => 'handshake issue' }
            );
        }
        if (centreon::gorgone::common::add_identity(dbh => $self->{db_gorgone}, identity => $identity, symkey => $symkey) == -1) {
            centreon::gorgone::common::zmq_core_response(
                socket => $self->{external_socket}, identity => $identity,
                code => 1, data => { message => 'handshake issue' }
            );
        }
        
        if (centreon::gorgone::common::zmq_core_key_response(logger => $self->{logger}, socket => $self->{external_socket}, identity => $identity,
                                                               hostname => $self->{hostname}, symkey => $symkey) == -1) {
            centreon::gorgone::common::zmq_core_response(
                socket => $self->{external_socket}, identity => $identity,
                code => 1, data => { message => 'handshake issue' }
            );
        }
        return undef;
    }    
}

sub router_external_event {
    while (1) {
        my ($identity, $key, $message) = $gorgone->handshake();
        if (defined($message)) {
            my ($token, $code, $response, $response_type) = $gorgone->message_run(message => $message);
            centreon::gorgone::common::zmq_core_response(
                socket => $gorgone->{external_socket},
                identity => $identity, response_type => $response_type,
                cipher => $gorgone_config->{gorgonecore}{cipher},
                vector => $gorgone_config->{gorgonecore}{vector},
                symkey => $key,
                token => $token, code => $code,
                data => $response
            );
        }
        last unless (centreon::gorgone::common::zmq_still_read(socket => $gorgone->{external_socket}));
    }
}

sub waiting_ready_pool {
    my (%options) = @_;
    
    my $time = time();
    # We wait 10 seconds
    while (time() - $time < 10) {
        foreach my $pool_id (keys %{$options{pool}})  {
            return 1 if ($options{pool}->{$pool_id}->{ready} == 1);
        }
        zmq_poll($gorgone->{poll}, 5000);
    }
    foreach my $pool_id (keys %{$options{pool}})  {
        return 1 if ($options{pool}->{$pool_id}->{ready} == 1);
    }
    
    return 0;
}

sub waiting_ready {
    my (%options) = @_;

    return 1 if (${$options{ready}} == 1);
    
    my $time = time();
    # We wait 10 seconds
    while (${$options{ready}} == 0 && 
           time() - $time < 10) {
        zmq_poll($gorgone->{poll}, 5000);
    }
    
    if (${$options{ready}} == 0) {
        return 0;
    }
    
    return 1;
}

sub clean_sessions {
    my ($self, %options) = @_;
    
    if ($self->{sessions_timer} - time() > $gorgone_config->{gorgonecore}{purge_sessions_time}) {
        $self->{logger}->writeLogInfo("purge sessions in progress...");
        $self->{db_gorgone}->query("DELETE FROM gorgone_identity WHERE `ctime` <  " . $self->{db_gorgone}->quote(time() - $gorgone_config->{gorgonecore}{sessions_time}));
        $self->{sessions_timer} = time();
    }
}

sub quit {
    my ($self, %options) = @_;
    
    $self->{logger}->writeLogInfo("Quit main process");
    zmq_close($self->{internal_socket});
    if (defined($gorgone_config->{gorgonecore}{external_com_type}) && $gorgone_config->{gorgonecore}{external_com_type} ne '') {
        zmq_close($self->{external_socket});
    }
    exit(0);
}

sub run {
    $gorgone = shift;

    $gorgone->SUPER::run();
    $gorgone->{logger}->redirect_output();

    $gorgone->{logger}->writeLogDebug("gorgoned launched....");
    $gorgone->{logger}->writeLogDebug("PID: $$");

    if (centreon::gorgone::common::add_history(dbh => $gorgone->{db_gorgone},
                                                 code => 0,
                                                 data => { msg => 'gorgoned is starting...' },
                                                 json_encode => 1) == -1) {
        $gorgone->{logger}->writeLogInfo("Cannot write in history. We quit!!");
        exit(1);
    }
    
    $gorgone->{internal_socket} = centreon::gorgone::common::create_com(
        type => $gorgone_config->{gorgonecore}{internal_com_type},
        path => $gorgone_config->{gorgonecore}{internal_com_path},
        zmq_type => 'ZMQ_ROUTER', name => 'router-internal',
        logger => $gorgone->{logger}
    );
    if (defined($gorgone_config->{gorgonecore}{external_com_type}) && $gorgone_config->{gorgonecore}{external_com_type} ne '') {
        $gorgone->{external_socket} = centreon::gorgone::common::create_com(
            type => $gorgone_config->{gorgonecore}{external_com_type},
            path => $gorgone_config->{gorgonecore}{external_com_path},
            zmq_type => 'ZMQ_ROUTER', name => 'router-external',
            logger => $gorgone->{logger}
        );
    }

    # Initialize poll set
    $gorgone->{poll} = [
        {
            socket  => $gorgone->{internal_socket},
            events  => ZMQ_POLLIN,
            callback => \&router_internal_event,
        }
    ];
    
    if (defined($gorgone->{external_socket})) {
        push @{$gorgone->{poll}}, {
            socket  => $gorgone->{external_socket},
            events  => ZMQ_POLLIN,
            callback => \&router_external_event,
        };
    }
    
    # init all modules
    foreach my $name (keys %{$gorgone->{modules_register}}) {
        $gorgone->{logger}->writeLogInfo("Call init function from module '$name'");
        $gorgone->{modules_register}->{$name}->{init}->(
            logger => $gorgone->{logger}, id => $gorgone->{id},
            poll => $gorgone->{poll},
            external_socket => $gorgone->{external_socket},
            internal_socket => $gorgone->{internal_socket},
            dbh => $gorgone->{db_gorgone}
        );
    }
    
    $gorgone->{logger}->writeLogInfo("[Server accepting clients]");

    while (1) {
        my $count = 0;
        my $poll = [@{$gorgone->{poll}}];
        
        foreach my $name (keys %{$gorgone->{modules_register}}) {
            $count += $gorgone->{modules_register}->{$name}->{check}->(
                logger => $gorgone->{logger},
                dead_childs => $gorgone->{return_child},
                internal_socket => $gorgone->{internal_socket},
                dbh => $gorgone->{db_gorgone},
                poll => $poll
            );
        }
        
        if ($gorgone->{stop} == 1) {
            # No childs
            if ($count == 0) {
                $gorgone->quit();
            }
            
            # Send KILL
            if (time() - $gorgone->{kill_timer} > $gorgone_config->{gorgonecore}{timeout}) {
                foreach my $name (keys %{$gorgone->{modules_register}}) {
                    $gorgone->{modules_register}->{$name}->{kill_internal}->(logger => $gorgone->{logger});
                }
                $gorgone->quit();
            }
        }

        zmq_poll($poll, 5000);

        $gorgone->clean_sessions();
    }
}

1;

__END__