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

package modules::scom::class;

use strict;
use warnings;
use centreon::gorgone::common;
use centreon::misc::objects::object;
use centreon::misc::http::http;
use ZMQ::LibZMQ4;
use ZMQ::Constants qw(:all);
use MIME::Base64;
use JSON::XS;
use Data::Dumper;

my %handlers = (TERM => {}, HUP => {});
my ($connector, $socket);

sub new {
    my ($class, %options) = @_;
    $connector  = {};
    $connector->{logger} = $options{logger};
    $connector->{container_id} = $options{container_id};
    $connector->{config} = $options{config};
    $connector->{config_core} = $options{config_core};
    $connector->{config_scom} = $options{config_scom};
    $connector->{config_db_centstorage} = $options{config_db_centstorage};
    $connector->{stop} = 0;

    $connector->{dsmhost} = $options{config_scom}->{dsmhost};
    $connector->{dsmslot} = $options{config_scom}->{dsmslot};
    $connector->{dsmmacro} = $options{config_scom}->{dsmmacro};
    $connector->{dsmalertmessage} = $options{config_scom}->{dsmalertmessage};
    $connector->{dsmrecoverymessage} = $options{config_scom}->{dsmrecoverymessage};
    $connector->{resync_time} = $options{config_scom}->{resync_time};
    $connector->{last_resync_time} = time() - $connector->{resync_time};
    $connector->{centcore_cmd} = 
        defined($connector->{config}->{centcore_cmd}) && $connector->{config}->{centcore_cmd} ne '' ? $connector->{config}->{centcore_cmd} : '/var/lib/centreon/centcore.cmd';

    $connector->{scom_session_id} = undef;

    $connector->{dsmclient_bin} = 
        defined($connector->{config}->{dsmclient_bin}) ? $connector->{config}->{dsmclient_bin} : '/usr/share/centreon/bin/dsmclient.pl';

    bless $connector, $class;
    $connector->set_signal_handlers();
    return $connector;
}

sub set_signal_handlers {
    my $self = shift;

    $SIG{TERM} = \&class_handle_TERM;
    $handlers{TERM}->{$self} = sub { $self->handle_TERM() };
    $SIG{HUP} = \&class_handle_HUP;
    $handlers{HUP}->{$self} = sub { $self->handle_HUP() };
}

sub handle_HUP {
    my $self = shift;
    $self->{reload} = 0;
}

sub handle_TERM {
    my $self = shift;
    $self->{logger}->writeLogInfo("gorgonescom $$ Receiving order to stop...");
    $self->{stop} = 1;
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

sub json_encode {
    my ($self, %options) = @_;

    my $encoded_arguments;
    eval {
        $encoded_arguments = JSON::XS->new->utf8->encode($options{argument});
    };
    if ($@) {
        $self->{logger}->writeLogError("gorgonescom: container $self->{container_id}: scom $options{method} - cannot encode json: $@");
        return 1;
    }

    return (0, $encoded_arguments);
}

sub http_check_error {
    my ($self, %options) = @_;

    if ($options{status} == 1) {
        $self->{logger}->writeLogError("gorgonescom: container $self->{container_id}: scom $options{method} issue");
        return 1;
    }

    my $code = $self->{http}->get_code();
    if ($code !~ /^2/) {
        $self->{logger}->writeLogError("gorgonescom: container $self->{container_id}: scom $options{method} issue - " . $self->{http}->get_message());
        return 1;
    }

    return 0;
}

sub scom_authenticate {
    my ($self, %options) = @_;

    my ($status) = $self->{http}->request(
        method => 'POST', hostname => '',
        full_url => $self->{config_scom}->{url} . '/OperationsManager/authenticate',
        credentials => 1, username => $self->{config_scom}->{username}, password => $self->{config_scom}->{password}, ntlmv2 => 1,
        query_form_post => '"' . MIME::Base64::encode_base64('Windows') . '"',
        header => [
            'Content-Type: application/json; charset=utf-8',
        ],
        curl_opt => ['CURLOPT_SSL_VERIFYPEER => 0'],
    );

    return 1 if ($self->http_check_error(status => $status, method => 'authenticate') == 1);

    my $header = $self->{http}->get_header(name => 'Set-Cookie');
    if (defined($header) && $header =~ /SCOMSessionId=([^;]+);/i) {
        $connector->{scom_session_id} = $1;
    } else {
        $self->{logger}->writeLogError("gorgonescom: container $self->{container_id}: scom authenticate issue - error retrieving cookie");
        return 1;
    }

    return 0;
}

sub get_realtime_scom_alerts {
    my ($self, %options) = @_;

    $self->{scom_realtime_alerts} = {};
    if (!defined($connector->{scom_session_id})) {
        return 1 if ($self->scom_authenticate() == 1);
    }

    my $arguments = {
        'classId' => '',
        'criteria' => "((ResolutionState <> '255') OR (ResolutionState <> '254'))",
        'displayColumns' => [
            'id', 'severity', 'resolutionState', 'monitoringobjectdisplayname', 'name', 'age', 'repeatcount', 'lastModified',
        ]
    };
    my ($status, $encoded_argument) = $self->json_encode(argument => $arguments);
    return 1 if ($status == 1);
    
    ($status, my $response) = $self->{http}->request(
        method => 'POST', hostname => '',
        full_url => $self->{config_scom}->{url} . '/OperationsManager/data/alert',
        query_form_post => $encoded_argument,
        header => [
            'Accept-Type: application/json; charset=utf-8',
            'Content-Type: application/json; charset=utf-8',
            'Cookie: SCOMSessionId=' . $self->{scom_session_id} . ';',
        ],
        curl_opt => ['CURLOPT_SSL_VERIFYPEER => 0'],
    );
    
    return 1 if ($self->http_check_error(status => $status, method => 'data/alert') == 1);

    $self->{scom_realtime_alerts} = {};
    print Data::Dumper::Dumper($response);

    return 0;
}

sub get_realtime_slots {
    my ($self, %options) = @_;

    $self->{realtime_slots} = [];
    my $request = "
        SELECT hosts.instance_id, hosts.name, services.description, services.state, cv.name, cv.value 
        FROM hosts, services 
        LEFT JOIN customvariables cv ON services.host_id = cv.host_id AND services.service_id = cv.service_id AND cv.name = '$self->{dsmmacro}'
        WHERE hosts.name = '$self->{dsmhost}' AND hosts.host_id = services.host_id AND services.enabled = '1' AND services.description LIKE '$self->{dsmslot}';
    ";
    my ($status, $datas) = $self->{class_object}->custom_execute(request => $request, mode => 2);
    return 1 if ($status == -1);
    foreach (@$datas) {
        my ($name, $id) = split('##', $$_[5]);
        push @{$self->{realtime_slots}}, {
            host_name => $$_[1],
            description => $$_[2],
            state => $$_[3],
            id => $id,
            instance_id => $$_[0],
        };
    }
}

sub action_scomresync {
    my ($self, %options) = @_;
    my ($status, $sth, $resource_configs);
    
    $self->{logger}->writeLogDebug("gorgonescom: container $self->{container_id}: begin resync");

    $self->get_realtime_slots();
    if (scalar(@{$self->{realtime_slots}}) <= 0) {
        $self->{logger}->writeLogError("gorgonescom: container $self->{container_id}: cannot find realtime slots");
        return 1;
    }

    if ($self->get_realtime_scom_alerts() == 0) {
        $self->{logger}->writeLogError("gorgonescom: container $self->{container_id}: cannot get scom realtime alerts");
        return 1;
    }

    return 0;
}

sub event {
    while (1) {
        my $message = centreon::gorgone::common::zmq_dealer_read_message(socket => $socket);
        
        $connector->{logger}->writeLogDebug("gorgonescom: class: $message");
        if ($message =~ /^\[(.*?)\]/) {
            if ((my $method = $connector->can('action_' . lc($1)))) {
                $message =~ /^\[(.*?)\]\s+\[(.*?)\]\s+\[.*?\]\s+(.*)$/m;
                my ($action, $token) = ($1, $2);
                my $data = JSON::XS->new->utf8->decode($3);
                while ($method->($connector, token => $token, data => $data)) {
                    # We block until it's fixed!!
                    sleep(5);
                }
            }
        }

        last unless (centreon::gorgone::common::zmq_still_read(socket => $socket));
    }
}

sub run {
    my ($self, %options) = @_;

    # Database creation. We stay in the loop still there is an error
    $self->{db_centstorage} = centreon::misc::db->new(
        dsn => $self->{config_db_centstorage}{dsn},
        user => $self->{config_db_centstorage}{username},
        password => $self->{config_db_centstorage}{password},
        force => 2,
        logger => $self->{logger}
    );
    ##### Load objects #####
    $self->{class_object} = centreon::misc::objects::object->new(logger => $self->{logger}, db_centreon => $self->{db_centstorage});
    $self->{http} = centreon::misc::http::http->new(logger => $self->{logger});

    # Connect internal
    $socket = centreon::gorgone::common::connect_com(
        zmq_type => 'ZMQ_DEALER', name => 'gorgonescom-' . $self->{container_id},
        logger => $self->{logger},
        type => $self->{config_core}{internal_com_type},
        path => $self->{config_core}{internal_com_path}
    );
    centreon::gorgone::common::zmq_send_message(
        socket => $socket,
        action => 'SCOMREADY', data => { container_id => $self->{container_id} },
        json_encode => 1
    );
    $self->{poll} = [
        {
            socket  => $socket,
            events  => ZMQ_POLLIN,
            callback => \&event,
        }
    ];
    while (1) {
        # we try to do all we can
        my $rev = zmq_poll($self->{poll}, 5000);
        if (defined($rev) && $rev == 0 && $self->{stop} == 1) {
            $self->{logger}->writeLogInfo("gorgonescom $$ has quit");
            zmq_close($socket);
            exit(0);
        }

        if (time() - $self->{resync_time} > $self->{last_resync_time}) {
            $self->{last_resync_time} = time();
            $self->action_scomresync();
        }
    }
}

1;