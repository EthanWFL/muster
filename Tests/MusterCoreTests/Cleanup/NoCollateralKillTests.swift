import Foundation
import Testing
@testable import MusterCore

/// R6 零误杀：每个用例都断言执行器拒绝，且信号发送器一次都没被调用。
@Suite struct NoCollateralKillTests {
    typealias F = CleanupFixture

    // MARK: - 对照组

    @Test func controlConfidentInTreeProcessIsTerminatedWithSigtermOnly() {
        let rig = CleanupRig()
        let outcome = rig.run(F.item(F.target(pid: 200, startOffset: 10)))
        #expect(outcome == .termSent)
        #expect(rig.signaller.calls.count == 1)
        #expect(rig.signaller.calls.first?.pid == 200)
        #expect(rig.signaller.calls.first?.signal == .term)
    }

    // MARK: - 同 cwd 前缀的无关进程

    @Test func unrelatedProcessSharingCwdPrefixIsRefused() {
        let rig = CleanupRig()
        // 即使计划里声称高置信度、在树内，执行层也以实时进程树为准
        let target = F.target(pid: 300, startOffset: 20, points: 100, inTree: true)
        let outcome = rig.run(F.item(target))
        #expect(outcome == .refused(.notInSessionTree))
        #expect(rig.signaller.calls.isEmpty)
        #expect(rig.log.messages.contains { $0.contains("REFUSED") })
    }

    @Test func unrelatedProcessWithLowScoreIsRefused() {
        let rig = CleanupRig()
        let target = F.target(pid: 300, startOffset: 20, points: 45, inTree: false)
        #expect(rig.run(F.item(target)) == .refused(.notInSessionTree))
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func orphanNotInTreeWithoutConfirmationIsRefused() {
        let rig = CleanupRig()
        let target = F.target(pid: 300, startOffset: 20, kind: .orphan, points: 85, inTree: false, ports: [])
        #expect(rig.run(F.item(target)) == .refused(.notInSessionTree))
        #expect(rig.signaller.calls.isEmpty)
    }

    // MARK: - PID 复用

    @Test func reusedPIDWithDifferentStartTimeIsRefused() {
        let rig = CleanupRig()
        // 计划时 pid 200 启动于 +10；现在同一个 pid 属于启动于 +5000 的另一个进程
        rig.table.set(F.record(200, ppid: 100, start: 5000, name: "node"))
        let outcome = rig.run(F.item(F.target(pid: 200, startOffset: 10)))
        #expect(outcome == .refused(.identityChanged))
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func reusedPIDIsRefusedEvenWithExplicitConfirmation() {
        let rig = CleanupRig()
        rig.table.set(F.record(200, ppid: 100, start: 5000, name: "node"))
        let outcome = rig.run(F.item(F.target(pid: 200, startOffset: 10)), confirmed: true)
        #expect(outcome == .refused(.identityChanged))
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func exitedProcessIsRefused() {
        let rig = CleanupRig()
        rig.table.remove(200)
        #expect(rig.run(F.item(F.target(pid: 200, startOffset: 10)), confirmed: true) == .refused(.processGone))
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func reusedSessionRootPIDDoesNotGrantTreeMembership() {
        let rig = CleanupRig()
        // session 根进程 pid 100 被别的进程复用：它的子树不再算 session 进程树
        rig.table.set(F.record(100, ppid: 50, start: 9000, name: "something-else"))
        let outcome = rig.run(F.item(F.target(pid: 200, startOffset: 10)))
        #expect(outcome == .refused(.notInSessionTree))
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func unknownSessionIsRefusedWithoutConfirmation() {
        let rig = CleanupRig()
        #expect(rig.run(F.item(F.target(pid: 200, startOffset: 10)), sessions: []) == .refused(.notInSessionTree))
        #expect(rig.signaller.calls.isEmpty)
    }

    // MARK: - pid 0 / 1 / 负数

    @Test(arguments: [Int32(0), 1, -1, Int32.min])
    func invalidPIDsAreRefusedEvenWhenConfirmed(pid: Int32) {
        let rig = CleanupRig()
        let target = F.target(pid: pid, startOffset: 0, points: 100, inTree: true)
        for confirmed in [false, true] {
            let outcome = rig.run(F.item(target), confirmed: confirmed)
            #expect(outcome == .refused(.invalidPID(pid)))
        }
        #expect(rig.signaller.calls.isEmpty)
    }

    // MARK: - app 自身

    @Test func ownPIDIsRefusedEvenWhenConfirmedAndInTree() {
        let rig = CleanupRig()
        // 4242 是 app 自身，且 ppid/cwd/启动时间都像 session 的子进程
        rig.table.set(F.record(4242, ppid: 100, start: 5, name: "Muster"))
        let target = F.target(pid: 4242, startOffset: 5, points: 100, inTree: true)
        for confirmed in [false, true] {
            #expect(rig.run(F.item(target), confirmed: confirmed) == .refused(.ownProcess))
        }
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func realGetpidIsRefusedEvenIfOwnPIDInjectionDiffers() {
        let rig = CleanupRig()
        let me = getpid()
        rig.table.set(F.record(me, ppid: 100, start: 5, name: "xctest"))
        let target = F.target(pid: me, startOffset: 5)
        #expect(rig.run(F.item(target), confirmed: true) == .refused(.ownProcess))
        #expect(rig.signaller.calls.isEmpty)
    }

    // MARK: - 不确定归属

    @Test func uncertainItemWithoutConfirmationIsRefusedEvenInTree() {
        let rig = CleanupRig()
        let target = F.target(pid: 200, startOffset: 10, points: 79)
        let item = F.item(target)
        #expect(item.isUncertain)
        #expect(!item.isPreselected)
        #expect(rig.run(item) == .refused(.uncertainOwnership))
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func uncertainItemIsNeverPreselectedInPlan() {
        let uncertain = F.item(F.target(pid: 200, startOffset: 10, points: 50, inTree: false))
        let confident = F.item(F.target(pid: 201, startOffset: 11, points: 100))
        let plan = CleanupPlan(createdAt: F.t0, items: [uncertain, confident])
        #expect(!plan.preselectedIDs.contains(uncertain.id))
        #expect(plan.preselectedIDs.contains(confident.id))
    }

    @Test func orphanIsNeverPreselected() {
        let orphan = F.item(F.target(pid: 300, startOffset: 20, kind: .orphan, points: 100, inTree: true, ports: []))
        #expect(!orphan.isPreselected)
    }

    @Test func unselectedItemsAreNeverExecuted() {
        let rig = CleanupRig()
        let item = F.item(F.target(pid: 200, startOffset: 10))
        let plan = CleanupPlan(createdAt: F.t0, items: [item])
        // 只"确认"但没有勾选：不能执行
        let report = rig.executor.execute(
            plan: plan, request: CleanupRequest(selected: [], confirmed: [item.id]), sessions: [F.session])
        #expect(report.entries.isEmpty)
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func confirmationOnAnotherItemDoesNotApply() {
        let rig = CleanupRig()
        let a = F.item(F.target(pid: 300, startOffset: 20, points: 45, inTree: false))
        let plan = CleanupPlan(createdAt: F.t0, items: [a])
        let report = rig.executor.execute(
            plan: plan, request: CleanupRequest(selected: [a.id], confirmed: ["kill:999:0"]), sessions: [F.session])
        #expect(report.entries.first?.outcome == .refused(.notInSessionTree))
        #expect(rig.signaller.calls.isEmpty)
    }

    // MARK: - 显式二次确认是唯一的例外路径

    @Test func explicitConfirmationAllowsOnlySigtermOnUnrelatedLookingProcess() {
        let rig = CleanupRig()
        let item = F.item(F.target(pid: 300, startOffset: 20, points: 45, inTree: false))
        #expect(rig.run(item, confirmed: true) == .termSent)
        #expect(rig.signaller.calls.count == 1)
        #expect(rig.signaller.calls.first?.signal == .term)
        #expect(rig.signaller.calls.first?.pid == 300)
    }

    // MARK: - SIGKILL

    @Test func sigkillWithoutPriorSigtermIsRefused() {
        let rig = CleanupRig()
        let target = F.target(pid: 200, startOffset: 10)
        rig.clock.advance(60)
        #expect(rig.executor.forceKill(target, userConfirmed: true) == .refused(.notTerminatedByUs))
        #expect(rig.signaller.calls.isEmpty)
    }

    @Test func sigkillBeforeGracePeriodOrWithoutConfirmationIsRefused() {
        let rig = CleanupRig()
        let target = F.target(pid: 200, startOffset: 10)
        #expect(rig.run(F.item(target)) == .termSent)
        rig.clock.advance(9)
        #expect(rig.executor.forceKill(target, userConfirmed: true) == .refused(.gracePeriodNotElapsed))
        rig.clock.advance(5)
        #expect(rig.executor.forceKill(target, userConfirmed: false) == .refused(.confirmationRequired))
        #expect(rig.signaller.calls.map(\.signal) == [.term])
    }

    @Test func sigkillAfterPIDReuseIsRefused() {
        let rig = CleanupRig()
        let target = F.target(pid: 200, startOffset: 10)
        #expect(rig.run(F.item(target)) == .termSent)
        rig.clock.advance(11)
        rig.table.set(F.record(200, ppid: 1, start: 7000, name: "unrelated"))
        #expect(rig.executor.forceKill(target, userConfirmed: true) == .refused(.identityChanged))
        #expect(rig.signaller.calls.map(\.signal) == [.term])
    }

    @Test func sigkillAfterGracePeriodAndConfirmationIsSent() {
        let rig = CleanupRig()
        let target = F.target(pid: 200, startOffset: 10)
        #expect(rig.run(F.item(target)) == .termSent)
        rig.clock.advance(10)
        #expect(rig.executor.forceKill(target, userConfirmed: true) == .done)
        #expect(rig.signaller.calls.map(\.signal) == [.term, .kill])
        #expect(rig.signaller.calls.allSatisfy { $0.pid == 200 })
    }

    @Test func sigkillRefusesInvalidAndOwnPIDs() {
        let rig = CleanupRig()
        for pid in [Int32(0), 1, rig.ownPID] {
            let target = F.target(pid: pid, startOffset: 0)
            rig.clock.advance(60)
            let outcome = rig.executor.forceKill(target, userConfirmed: true)
            if case .refused = outcome {} else { Issue.record("pid \(pid) was not refused: \(outcome)") }
        }
        #expect(rig.signaller.calls.isEmpty)
    }

    // MARK: - 展示命令与执行一致 (R7)

    @Test func displayedCommandIsDerivedFromTheExecutedTarget() {
        let target = F.target(pid: 200, startOffset: 10)
        let item = F.item(target)
        #expect(item.command.argv == ["kill", "-TERM", "200"])
        #expect(item.command.displayText == "kill -TERM 200")
        #expect(CleanupPlan(createdAt: F.t0, items: [item]).commandTexts == ["kill -TERM 200"])
    }

    // MARK: - 真实信号层的纵深防御

    @Test func systemSignallerRefusesDangerousPIDsWithoutSending() {
        let signaller = SystemProcessSignaller()
        for pid in [Int32(0), 1, -1, getpid()] {
            #expect(throws: (any Error).self) { try signaller.send(.term, to: pid) }
        }
    }
}
