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

    MainActor.assumeIsolated {
        T.group("remote URL keeps an alias with '/' intact (#70)") {
            // VSCode-style grouped aliases ("homelab/nuc/-root") aren't valid in a
            // URL host; remoteURL must encode them so remoteHost decodes back fully
            // instead of collapsing to the first segment ("homelab").
            let alias = "homelab/soyo/-root"
            let url = BrowserModel.remoteURL(host: alias, path: "/home/dearmai")
            T.equal(url.scheme, "sftp", "scheme is sftp")
            T.equal(url.host, alias, "the full grouped alias survives (not just 'homelab')")
            T.equal(url.path, "/home/dearmai", "path preserved")
            // An '@' in the alias survives too.
            let at = BrowserModel.remoteURL(host: "user@box/x", path: "/")
            T.equal(at.host, "user@box/x", "'@' and '/' in the alias both survive")
            // A plain alias is unchanged.
            T.equal(BrowserModel.remoteURL(host: "prod", path: "/var").host, "prod",
                    "a normal alias round-trips unchanged")
        }
    }
}
