/// Tracks owners rather than counting repeated callbacks. No OS event dependency.
public struct HoldLedger {
    public private(set) var owners: [UInt16: Set<String>] = [:]
    public init() {}
    public mutating func set(_ key: UInt16, owner: String, down: Bool) -> Bool {
        let was = !(owners[key] ?? []).isEmpty
        if down { owners[key, default: []].insert(owner) }
        else { owners[key]?.remove(owner); if owners[key]?.isEmpty == true { owners[key] = nil } }
        return was != !(owners[key] ?? []).isEmpty
    }
    public mutating func clear() -> [UInt16] {
        let keys = Array(owners.keys).sorted(); owners.removeAll(); return keys
    }
}
public struct Hysteresis {
    public private(set) var down = false
    public init() {}
    public mutating func update(_ value: Float) -> Bool {
        if down { if value <= 0.30 { down = false } }
        else if value >= 0.55 { down = true }
        return down
    }
}
/// Press immediately; accept release only after a short continuous neutral period.
/// Repeated held callbacks and short false packets cannot retrigger a shortcut.
public struct StableButton {
    public private(set) var down=false
    public private(set) var pendingRelease:Double?
    public var releaseDelay=0.035
    public init() {}
    public mutating func update(_ raw:Bool,time:Double)->Bool {
        if raw {down=true;pendingRelease=nil}
        else if down {
            if let start=pendingRelease {if time-start >= releaseDelay {down=false;pendingRelease=nil}}
            else {pendingRelease=time}
        }
        return down
    }
}

/// Stateful gesture recognition independent of operating-system keyboard output.
/// Chords reserve their members until neutral. Prefix singles wait briefly so
/// completing a chord cannot first fire its members' ordinary actions.
public struct GestureRouter {
    public var doubleInterval=0.32
    public var holdDelay=0.18
    public var chordGrace=0.18
    private struct Sequence {
        var previous=false
        var downAt=0.0
        var firstUp:Double?
        var second=false
    }
    private struct State {var previous=false;var downAt=0.0;var active=false;var fired=false;var pulseUntil:Double?}
    private var sequences:[String:Sequence]=[:]
    private var states:[String:State]=[:]
    private var blocked:Set<PadControl>=[]
    private var claimed:Set<PadControl>=[]
    public private(set) var hasPending=false
    public init() {}
    public mutating func suspend(held:Set<PadControl>) {
        sequences.removeAll();states.removeAll();blocked.formUnion(held);claimed.removeAll();hasPending=false
    }
    private func groupID(_ b:MappingBinding)->String {
        b.control.rawValue+":"+b.companions.map(\.rawValue).sorted().joined(separator:"+")
    }
    /// Compatibility surface for consumers that only need physical controls.
    public mutating func update(bindings:[MappingBinding],held:Set<PadControl>,time:Double,allowed:Bool)->Set<PadControl> {
        let ids=updateBindings(bindings:bindings,held:held,time:time,allowed:allowed)
        return Set(bindings.filter{ids.contains($0.id)}.map(\.control))
    }
    public mutating func updateBindings(bindings:[MappingBinding],held:Set<PadControl>,time:Double,allowed:Bool)->Set<String> {
        blocked.formIntersection(held);claimed.formIntersection(held)
        guard allowed else{suspend(held:held);return []}
        let enabled=bindings.filter{$0.mode != .disabled}
        let groups=Dictionary(grouping:enabled,by:groupID)
        let chords=enabled.filter{!$0.companions.isEmpty}.sorted{($0.companions.count,$0.id)>($1.companions.count,$1.id)}
        var winners:Set<String>=[],members:Set<PadControl>=[]
        for b in chords {
            let group=Set(b.companions+[b.control]),id=groupID(b)
            if winners.contains(id){continue}
            if group.isSubset(of:held),group.isDisjoint(with:blocked),group.isDisjoint(with:members) {
                winners.insert(id);members.formUnion(group);claimed.formUnion(group)
            }
        }
        let prefixes=Set(chords.flatMap{$0.companions+[$0.control]})
        var result:Set<String>=[];hasPending=false
        for (id,bindings) in groups {
            guard let first=bindings.first else{continue}
            let raw=held.contains(first.control) && !blocked.contains(first.control)
                && (first.companions.isEmpty ? !claimed.contains(first.control):winners.contains(id))
            let hasDouble=bindings.contains{$0.gesture != .press}
            let hasFallback=bindings.contains{$0.gesture == .press}
            let hasDoubleHold=bindings.contains{$0.gesture == .doubleHold}
            var q=sequences[id] ?? Sequence()
            let down=raw && !q.previous,up = !raw && q.previous
            let expiredFirst=q.firstUp.map{time-$0>=doubleInterval} ?? false
            if expiredFirst {q.firstUp=nil}
            if down {q.second=q.firstUp != nil;q.firstUp=nil;q.downAt=time}
            let second=q.second,duration=time-q.downAt
            if up {q.firstUp = !second && (!hasFallback || duration<holdDelay) ? time:nil}
            for b in bindings {
                var s=states[b.id] ?? State()
                let delayedChord=first.companions.isEmpty && prefixes.contains(first.control)
                if down {s.downAt=time;s.pulseUntil=nil;s.fired=false}
                switch b.gesture {
                case .press:
                    if hasDouble {
                        if b.mode == .hold {
                            s.active=raw && !second && duration>=max(holdDelay,delayedChord ? chordGrace:0)
                            if raw && !second && !s.active {hasPending=true}
                        } else {
                            // A single tap waits for the double-click window. A second
                            // press claims it before it can emit an ordinary action.
                            if down && second {s.pulseUntil=nil}
                            if !raw,expiredFirst {s.pulseUntil=time+0.025}
                            if raw && !second && duration>=doubleInterval && !s.fired {s.pulseUntil=time+0.025;s.fired=true}
                            if raw && !second && !s.fired {hasPending=true}
                            s.active=s.pulseUntil.map{time<$0} ?? false
                        }
                    } else if raw {s.active = !delayedChord || duration>=chordGrace}
                    else {
                        if up,delayedChord,!s.active,!claimed.contains(first.control){s.pulseUntil=time+0.025}
                        s.active=s.pulseUntil.map{time<$0} ?? false
                    }
                    if raw && !s.active && delayedChord || s.pulseUntil.map({time<$0}) == true {hasPending=true}
                case .doubleTap:
                    if hasDoubleHold {
                        if up && second && duration<holdDelay {s.pulseUntil=time+0.025}
                        s.active=s.pulseUntil.map{time<$0} ?? false
                    } else {s.active=raw && second}
                case .doubleHold:
                    s.active=raw && second && duration>=holdDelay
                    if raw && second && !s.active {hasPending=true}
                }
                if !raw,claimed.contains(first.control),first.companions.isEmpty {s=State()}
                if s.pulseUntil.map({time<$0}) == true {hasPending=true}
                s.previous=raw;states[b.id]=s
                if s.active {result.insert(b.id)}
            }
            if q.firstUp != nil {hasPending=true}
            if up {q.second=false}
            q.previous=raw;sequences[id]=q
        }
        return result
    }
}
/// A button held across a scope transition must return to neutral first.
public struct InputGate {
    private var active: Set<String> = []
    private var blocked: Set<String> = []
    public init() {}
    public mutating func update(_ id: String, down: Bool, allowed: Bool) -> Bool? {
        if !allowed {
            if down { blocked.insert(id) } else { blocked.remove(id) }
            active.remove(id); return nil
        }
        if blocked.contains(id) {
            if !down { blocked.remove(id) }; return nil
        }
        let previous = active.contains(id)
        if down { active.insert(id) } else { active.remove(id) }
        return previous == down ? nil : down
    }
    public mutating func suspend() { blocked.formUnion(active); active.removeAll() }
}
