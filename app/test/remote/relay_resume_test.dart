import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_relay.dart';

/// A tunnel that survived only until the app went to the background: the probe
/// fails, as a dead WebRTC/relay session does on an iPhone.
class DeadTunnelRelay extends FakeRelayBackend {
  DeadTunnelRelay({super.user});

  @override
  Future<bool> probe(DshClient client) async {
    probes++;
    throw const SocketExceptionLike();
  }
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

/// A tunnel whose probe reports a route change: the probe itself already
/// reconnected, so the link must not start a second one.
class RenegotiatedRelay extends FakeRelayBackend {
  RenegotiatedRelay({super.user});

  @override
  Future<bool> probe(DshClient client) async {
    probes++;
    return false;
  }
}

void main() {
  test('a failed resume probe reconnects the live client at once', () async {
    final relay = DeadTunnelRelay(user: sampleRelayUser);
    final link = RelayHostLink(backend: relay, hostId: 'mac', resolveHost: () async => sampleRelayHosts.first);
    addTearDown(link.close);

    final client = await link.open();
    expect(link.status.phase, HostLinkPhase.connected);

    link.kick();
    await pumpEventQueue();

    expect(relay.probes, 1);
    expect(relay.reconnected, [client]);
    expect(link.status.phase, HostLinkPhase.reconnecting);
  });

  test('a healthy probe leaves the connection alone', () async {
    final relay = FakeRelayBackend(user: sampleRelayUser);
    final link = RelayHostLink(backend: relay, hostId: 'mac', resolveHost: () async => sampleRelayHosts.first);
    addTearDown(link.close);

    await link.open();
    link.kick();
    await pumpEventQueue();

    expect(relay.probes, 1);
    expect(relay.reconnected, isEmpty);
    expect(link.status.phase, HostLinkPhase.connected);
  });

  test('a probe that already renegotiated does not reconnect twice', () async {
    final relay = RenegotiatedRelay(user: sampleRelayUser);
    final link = RelayHostLink(backend: relay, hostId: 'mac', resolveHost: () async => sampleRelayHosts.first);
    addTearDown(link.close);

    await link.open();
    link.kick();
    await pumpEventQueue();

    // The first reconnect comes from the route change inside the probe; the
    // link stays quiet rather than issuing a second one.
    expect(relay.reconnected, hasLength(1));
  });

  test('a reconnect inside the cache window skips the directory lookup', () async {
    var lookups = 0;
    final relay = DeadTunnelRelay(user: sampleRelayUser);
    final link = RelayHostLink(
      backend: relay,
      hostId: 'mac',
      resolveHost: () async {
        lookups++;
        return sampleRelayHosts.first;
      },
    );
    addTearDown(link.close);

    final client = await link.open();
    expect(lookups, 1);
    // The client is gone for good, so the probe's recovery has to connect
    // again -- and reuses the presence it just resolved.
    relay.closedClients.add(client);

    link.kick();
    await pumpEventQueue(times: 50);

    expect(lookups, 1);
    expect(relay.connected, ['mac', 'mac']);
  });

  test('an explicit retry resolves the host again after the cache window', () async {
    var lookups = 0;
    final relay = FakeRelayBackend(
      user: sampleRelayUser,
      hosts: const [RelayHost(id: 'mac', name: '家里的 Mac', online: false)],
    );
    final link = RelayHostLink(
      backend: relay,
      hostId: 'mac',
      resolveHost: () async {
        lookups++;
        return relay.hosts.isEmpty ? null : relay.hosts.first;
      },
      backoff: Backoff(initial: const Duration(milliseconds: 1), max: const Duration(milliseconds: 2), maxAttempts: 1),
    );
    addTearDown(link.close);

    await expectLater(link.open(), throwsA(isA<HostLinkError>()));
    expect(lookups, 1);

    relay.hosts = const [RelayHost(id: 'mac', name: '家里的 Mac', online: true)];
    link.retry();
    await pumpEventQueue(times: 50);

    expect(lookups, 2);
    expect(relay.connected, ['mac']);
  });
}
