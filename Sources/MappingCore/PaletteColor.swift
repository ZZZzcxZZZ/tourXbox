import Foundation

/// Exact inscribed shapes for the clear interior of a stroked hue ring.
public struct PaletteWheelGeometry {
    public let innerRadius:Double
    public var squareSide:Double {innerRadius * sqrt(2)}
    public var triangleWidth:Double {innerRadius * 1.5}
    public var triangleHeight:Double {innerRadius * sqrt(3)}
    public var triangleCenterOffset:Double {innerRadius / 4}
    public init(diameter:Double,ringWidth:Double,contentInset:Double=0){innerRadius=max(0,diameter/2-ringWidth-contentInset)}
}

/// Components are sRGB normalized to 0...1. Lab is our documented D65 approximation,
/// not TourBox's unpublished Luma algorithm or an arbitrary Photoshop document profile.
public struct PaletteRGB: Equatable, Codable, Sendable {
    public var r:Double; public var g:Double; public var b:Double
    public init(_ r:Double,_ g:Double,_ b:Double) {self.r=r;self.g=g;self.b=b}
    public var clipped: Self {Self(Self.clamp(r),Self.clamp(g),Self.clamp(b))}
    public var inGamut: Bool {r.isFinite && g.isFinite && b.isFinite && min(r,g,b) >= -0.00001 && max(r,g,b) <= 1.00001}
    public static func clamp(_ x:Double)->Double {x.isFinite ? min(1,max(0,x)) : 0}
    public static func wrap(_ h:Double)->Double {h.isFinite ? h-floor(h) : 0}
    public static func hsv(_ h:Double,_ s:Double,_ v:Double)->Self {
        let h=wrap(h)*6,s=clamp(s),v=clamp(v),c=v*s,x=c*(1-abs(h.truncatingRemainder(dividingBy:2)-1)),m=v-c
        let p:Self
        switch Int(h) {case 0:p=Self(c,x,0);case 1:p=Self(x,c,0);case 2:p=Self(0,c,x);case 3:p=Self(0,x,c);case 4:p=Self(x,0,c);default:p=Self(c,0,x)}
        return Self(p.r+m,p.g+m,p.b+m)
    }
    public static func hsl(_ h:Double,_ s:Double,_ l:Double)->Self {
        let l=clamp(l),c=(1-abs(2*l-1))*clamp(s),v=l+c/2
        return hsv(h,v == 0 ? 0:c/v,v)
    }
    public var hsv:(h:Double,s:Double,v:Double) {
        let hi=max(r,g,b),lo=min(r,g,b),d=hi-lo
        var h=0.0
        if d>1e-10 {if hi==r {h=(g-b)/d} else if hi==g {h=2+(b-r)/d} else {h=4+(r-g)/d}}
        return (Self.wrap(h/6),hi<=0 ? 0:d/hi,hi)
    }
    public var hsl:(h:Double,s:Double,l:Double) {
        let hi=max(r,g,b),lo=min(r,g,b),l=(hi+lo)/2,d=hi-lo,den=1-abs(2*l-1)
        return (hsv.h,den<1e-10 ? 0:d/den,l)
    }
    public var lab:(l:Double,a:Double,b:Double) {
        func linear(_ v:Double)->Double {v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
        let rr=linear(r),gg=linear(g),bb=linear(b)
        func f(_ t:Double)->Double {t>216.0/24389 ? pow(t,1.0/3):(24389.0/27*t+16)/116}
        let x=f((0.4124564*rr+0.3575761*gg+0.1804375*bb)/0.95047)
        let y=f(0.2126729*rr+0.7151522*gg+0.0721750*bb)
        let z=f((0.0193339*rr+0.1191920*gg+0.9503041*bb)/1.08883)
        return (116*y-16,500*(x-y),200*(y-z))
    }
    public static func lab(_ l:Double,_ a:Double,_ b:Double)->Self {
        let fy=(l+16)/116,fx=fy+a/500,fz=fy-b/200
        func inv(_ v:Double)->Double {let c=v*v*v;return c>216.0/24389 ? c:(116*v-16)/(24389.0/27)}
        let x=0.95047*inv(fx),y=inv(fy),z=1.08883*inv(fz)
        func gamma(_ v:Double)->Double {v<=0.0031308 ? 12.92*v:1.055*pow(v,1/2.4)-0.055}
        return Self(gamma(3.2404542*x-1.5371385*y-0.4985314*z),gamma(-0.9692660*x+1.8760108*y+0.0415560*z),gamma(0.0556434*x-0.2040259*y+1.0572252*z))
    }
    /// Equilateral HSL triangle: hue at right, white top-left, black bottom-left.
    public static func triangle(_ x:Double,_ y:Double)->(s:Double,l:Double) {
        let hue=clamp(x),white=min(1-hue,max(0,1-y-hue/2)),l=white+hue/2,den=1-abs(2*l-1)
        return (den>1e-9 ? clamp(hue/den):0,clamp(l))
    }
    public static func trianglePoint(s:Double,l:Double)->(x:Double,y:Double) {
        let c=(1-abs(2*l-1))*s
        return (c,1-l)
    }
}
