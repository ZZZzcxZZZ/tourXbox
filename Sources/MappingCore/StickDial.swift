import Foundation

/// Relative rotary recognizer integrated into the dynamic palette; no direct OS output.
public struct StickDialPrototype {
    public var engageRadius=0.60
    public var releaseRadius=0.40
    public var maximumGap=0.20
    public var maximumPacketAngle=Double.pi/2
    public var stepsPerTurn=48.0
    public var gain=1.0
    public var minimumArc=Double.pi/180
    public init() {}
    private var engaged=false
    private var previousAngle:Double?
    private var previousTime:Double?
    private var remainder=0.0
    private var pendingArc=0.0
    public mutating func reset() {engaged=false;previousAngle=nil;previousTime=nil;remainder=0;pendingArc=0}
    public mutating func update(x:Double,y:Double,time:Double,enabled:Bool=true)->(radians:Double,steps:Int) {
        guard enabled,x.isFinite,y.isFinite,time.isFinite else {reset();return (0,0)}
        let radius=hypot(x,y)
        guard radius >= (engaged ? releaseRadius : engageRadius) else {reset();return (0,0)}
        engaged=true
        let angle=atan2(y,x)
        defer {previousAngle=angle;previousTime=time}
        guard let previousAngle,let previousTime,time>previousTime,time-previousTime<=maximumGap else {remainder=0;pendingArc=0;return (0,0)}
        // GameController y is positive upwards. Clockwise output is positive.
        let delta = -atan2(sin(angle-previousAngle),cos(angle-previousAngle))
        guard abs(delta)<=maximumPacketAngle else {remainder=0;pendingArc=0;return (0,0)}
        pendingArc += delta*gain
        guard abs(pendingArc)>=minimumArc else{return(0,0)}
        let scaled=pendingArc;pendingArc=0
        remainder += scaled
        let stepAngle=2*Double.pi/stepsPerTurn
        let quotient=remainder/stepAngle
        let adjusted=quotient+(quotient>=0 ? 1e-9 : -1e-9)
        let steps=Int(adjusted.rounded(.towardZero))
        remainder -= Double(steps)*stepAngle
        return (scaled,steps)
    }
}
