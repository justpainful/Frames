import CoreGraphics

extension CGRect {
    /// True when this rect can be used as a Core Image render extent.
    ///
    /// Core Image happily hands back infinite extents from generators and null
    /// extents from failed filters, and either one turns a subsequent
    /// rasterisation into an allocation the size of the address space. Every
    /// stage checks this before sizing anything from an extent.
    var isRenderable: Bool {
        !isNull && !isInfinite && width > 0 && height > 0
    }
}
