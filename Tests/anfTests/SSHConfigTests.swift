import Foundation
@testable import anf

/// `SSHConfig.parse` reads ~/.ssh/config for the sidebar SSH section — pure now
/// that it's split from file I/O, and previously untested.
func runSSHConfigTests() {
    T.group("parses aliases + hostname, dedupes") {
        let cfg = """
        # work hosts
        Host prod
            HostName 10.0.0.1
            User deploy

        Host db1 db2
            HostName db.internal

        Host prod
            HostName dupe.ignored
        """
        let hosts = SSHConfig.parse(cfg)
        T.equal(hosts.map(\.alias), ["prod", "db1", "db2"], "aliases in order, second 'prod' deduped")
        T.equal(hosts.first { $0.alias == "prod" }?.hostName, "10.0.0.1", "hostname captured")
        T.equal(hosts.first { $0.alias == "db1" }?.hostName, "db.internal", "shared hostname for multi-alias Host")
    }

    T.group("skips wildcard patterns and comments") {
        let cfg = """
        Host *
            ForwardAgent yes
        Host *.example.com
            User x
        Host bastion # inline comment
            HostName b.example.com
        """
        let hosts = SSHConfig.parse(cfg)
        T.equal(hosts.map(\.alias), ["bastion"], "wildcards (* and ?) excluded; only concrete host kept")
        T.equal(hosts.first?.hostName, "b.example.com", "hostname parsed despite earlier wildcard blocks")
    }

    T.group("empty / no hosts") {
        T.expect(SSHConfig.parse("").isEmpty, "empty config → no hosts")
        T.expect(SSHConfig.parse("# just a comment\nForwardAgent yes").isEmpty, "no Host lines → none")
    }
}
