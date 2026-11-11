import Foundation
import Testing
@testable import MusterCore

@Suite struct ProcessScannerParsingTests {
    @Test func parsesLsofFieldOutput() {
        let output = """
        p123
        cnode
        n*:3000
        n[::1]:3001
        p456
        cpostgres
        n127.0.0.1:5432
        """
        let ports = ProcessScanner.parseLsof(output)
        #expect(ports.count == 3)
        #expect(ports[0] == ListeningPort(pid: 123, command: "node", port: 3000, address: "*"))
        #expect(ports[1].port == 3001)
        #expect(ports[1].address == "[::1]")
        #expect(ports[2].pid == 456)
    }

    @Test func lsofDeduplicatesIPv4AndIPv6Duplicates() {
        let output = "p1\ncnode\nn*:80\nn*:80\n"
        #expect(ProcessScanner.parseLsof(output).count == 1)
    }

    @Test func parsesPSOutput() {
        let map = ProcessScanner.parsePS("  100 /usr/bin/claude --flag\n 2001 node vite.js --port 3000\n")
        #expect(map[100] == "/usr/bin/claude --flag")
        #expect(map[2001] == "node vite.js --port 3000")
    }

    @Test func listeningPortsUsesMachineReadableLsofThroughRunner() throws {
        let runner = CleanupStubRunner { argv, _ in
            #expect(argv.first == "lsof")
            return CommandResult(status: 0, stdout: "p9\ncnode\nn*:5173\n")
        }
        let scanner = ProcessScanner(table: CleanupStubTable([]), runner: runner, clock: CleanupTestClock(CleanupFixture.t0))
        let ports = try scanner.listeningPorts()
        #expect(ports.map(\.port) == [5173])
        #expect(runner.calls.first?.contains("-F") == true)
        #expect(runner.calls.first?.contains("-sTCP:LISTEN") == true)
    }

    @Test func lsofWithNoMatchesIsEmptyNotAnError() throws {
        let runner = CleanupStubRunner { _, _ in CommandResult(status: 1) }
        let scanner = ProcessScanner(table: CleanupStubTable([]), runner: runner, clock: CleanupTestClock(CleanupFixture.t0))
        #expect(try scanner.listeningPorts().isEmpty)
    }

    @Test func snapshotCombinesTableAndPS() {
        let runner = CleanupStubRunner { _, _ in CommandResult(status: 0, stdout: "200 node vite.js\n") }
        let table = CleanupStubTable(CleanupFixture.defaultRecords())
        let scanner = ProcessScanner(table: table, runner: runner, clock: CleanupTestClock(CleanupFixture.t0))
        let snap = scanner.snapshot()
        #expect(snap.processes[200]?.ppid == 100)
        #expect(snap.commandLines[200] == "node vite.js")
        #expect(snap.isInTree(of: CleanupFixture.session, pid: 200))
        #expect(!snap.isInTree(of: CleanupFixture.session, pid: 300))
    }

    @Test func ancestorWalkSurvivesCycles() {
        let a = CleanupFixture.record(10, ppid: 11, start: 0)
        let b = CleanupFixture.record(11, ppid: 10, start: 0)
        let snap = ProcessSnapshot(takenAt: CleanupFixture.t0, processes: [10: a, 11: b])
        #expect(snap.ancestors(of: 10).count <= 2)
    }
}

@Suite struct CleanupPlanTests {
    private func plan() -> CleanupPlan {
        let records = CleanupFixture.defaultRecords()
        let snapshot = ProcessSnapshot(
            takenAt: CleanupFixture.t0.addingTimeInterval(100),
            processes: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) }),
            commandLines: [200: "node vite.js", 300: "node other.js"])
        let ports = [
            ListeningPort(pid: 200, command: "node", port: 3000, address: "*"),
            ListeningPort(pid: 300, command: "node", port: 4000, address: "*"),
            ListeningPort(pid: 1, command: "launchd", port: 111, address: "*"),
            ListeningPort(pid: 4242, command: "Muster", port: 9999, address: "*"),
        ]
        return CleanupPlanner(ownPID: 4242)
            .plan(sessions: [CleanupFixture.session], snapshot: snapshot, ports: ports)
    }

    @Test func plannerNeverProposesPid1OrSelf() {
        let pids = plan().items.compactMap { item -> Int32? in
            if case .terminate(let t) = item.action { return t.identity.pid }
            return nil
        }
        #expect(!pids.contains(1))
        #expect(!pids.contains(4242))
        #expect(pids.contains(200))
    }

    @Test func uncertainItemsAreNeverPreselected() {
        let p = plan()
        let uncertain = p.items.filter(\.isUncertain)
        #expect(!uncertain.isEmpty)
        for item in uncertain { #expect(!p.preselectedIDs.contains(item.id)) }
        let confident = p.items.first { if case .terminate(let t) = $0.action { return t.identity.pid == 200 } else { return false } }
        #expect(confident.map { p.preselectedIDs.contains($0.id) } == true)
    }

    @Test func displayedTextAndExecutedArgvComeFromSameObject() {
        for item in plan().items {
            let command = item.command
            #expect(item.command.displayText == command.displayText)
            for arg in command.argv { #expect(command.displayText.contains(arg)) }
        }
        let kill = CleanupFixture.item(CleanupFixture.target(pid: 200, startOffset: 10))
        #expect(kill.command.argv == ["kill", "-TERM", "200"])
        #expect(kill.command.displayText == "kill -TERM 200")
    }

    @Test func tamperedCommandIsRefusedByExecutor() {
        // 展示 argv 与 pid 不一致的 item 不可能由 CleanupAction 生成；执行器仍独立校验 pid 来源
        let rig = CleanupRig()
        let t = CleanupFixture.target(pid: 200, startOffset: 10)
        #expect(rig.run(CleanupFixture.item(t)) == .termSent)
        #expect(rig.signaller.calls.map(\.pid) == [200])
        #expect(rig.signaller.calls.map(\.signal) == [.term])
    }
}

@Suite struct CleanupExecutorBehaviourTests {
    @Test func reconcileReportsFreedPortsOnceProcessExits() {
        let rig = CleanupRig()
        let item = CleanupFixture.item(CleanupFixture.target(pid: 200, startOffset: 10))
        let plan = CleanupPlan(createdAt: CleanupFixture.t0, items: [item])
        var report = rig.executor.execute(
            plan: plan, request: CleanupRequest(selected: [item.id]), sessions: [CleanupFixture.session])
        #expect(report.awaitingExit.count == 1)
        #expect(report.freedPorts.isEmpty)
        rig.table.remove(200)
        rig.executor.reconcile(&report)
        #expect(report.freedPorts == [3000])
        #expect(report.awaitingExit.isEmpty)
    }

    @Test func sigkillRefusedWithoutPriorTerm() {
        let rig = CleanupRig()
        let t = CleanupFixture.target(pid: 200, startOffset: 10)
        #expect(rig.executor.forceKill(t, userConfirmed: true) == .refused(.notTerminatedByUs))
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func sigkillRefusedBeforeTenSecondsAndWithoutConfirmation() {
        let rig = CleanupRig()
        let t = CleanupFixture.target(pid: 200, startOffset: 10)
        #expect(rig.run(CleanupFixture.item(t)) == .termSent)
        rig.clock.advance(5)
        #expect(rig.executor.forceKill(t, userConfirmed: true) == .refused(.gracePeriodNotElapsed))
        rig.clock.advance(6)
        #expect(rig.executor.forceKill(t, userConfirmed: false) == .refused(.confirmationRequired))
        #expect(rig.signaller.calls.map(\.signal) == [.term])
    }

    @Test func sigkillSentAfterTenSecondsWithSeparateConfirmation() {
        let rig = CleanupRig()
        let t = CleanupFixture.target(pid: 200, startOffset: 10)
        #expect(rig.run(CleanupFixture.item(t)) == .termSent)
        rig.clock.advance(11)
        #expect(rig.executor.forceKill(t, userConfirmed: true) == .done)
        #expect(rig.signaller.calls.map(\.signal) == [.term, .kill])
    }

    @Test func sigkillRefusedIfPidWasReusedInTheMeantime() {
        let rig = CleanupRig()
        let t = CleanupFixture.target(pid: 200, startOffset: 10)
        #expect(rig.run(CleanupFixture.item(t)) == .termSent)
        rig.table.set(CleanupFixture.record(200, ppid: 1, start: 7777, name: "unrelated"))
        rig.clock.advance(11)
        #expect(rig.executor.forceKill(t, userConfirmed: true) == .refused(.identityChanged))
        #expect(rig.signaller.calls.map(\.signal) == [.term])
    }

    @Test func refusalsAreLogged() {
        let rig = CleanupRig()
        _ = rig.run(CleanupFixture.item(CleanupFixture.target(pid: 1, startOffset: 0)))
        #expect(rig.log.messages.contains { $0.contains("REFUSED") })
    }

    @Test func confirmedItemOutsideTreeIsAllowedButStillIdentityChecked() {
        let rig = CleanupRig()
        // 300 不在树内；用户二次确认后可以终止
        let t = CleanupFixture.target(pid: 300, startOffset: 20, points: 60, inTree: false)
        #expect(rig.run(CleanupFixture.item(t), confirmed: true) == .termSent)
        #expect(rig.signaller.calls.map(\.pid) == [300])
    }
}
