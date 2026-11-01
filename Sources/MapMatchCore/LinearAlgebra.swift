import Foundation

/// Solves A·X = B for X by Gaussian elimination with partial pivoting.
/// `a` is n×n row-major, `b` is n×m row-major. Returns nil if A is (numerically) singular.
/// The systems here are small (≤ a few hundred unknowns), so a dense solver is plenty.
func solveLinearSystem(_ a: [Double], _ b: [Double], n: Int, rhsColumns m: Int) -> [Double]? {
    var A = a, B = b
    let scale = A.map(abs).max() ?? 1
    let eps = 1e-12 * max(scale, 1e-300)
    for col in 0..<n {
        var pivot = col
        var best = abs(A[col * n + col])
        for r in (col + 1)..<max(n, col + 1) where abs(A[r * n + col]) > best {
            best = abs(A[r * n + col]); pivot = r
        }
        if best <= eps { return nil }
        if pivot != col {
            for c in 0..<n { A.swapAt(col * n + c, pivot * n + c) }
            for c in 0..<m { B.swapAt(col * m + c, pivot * m + c) }
        }
        let d = A[col * n + col]
        for r in (col + 1)..<max(n, col + 1) {
            let factor = A[r * n + col] / d
            if factor == 0 { continue }
            for c in col..<n { A[r * n + c] -= factor * A[col * n + c] }
            for c in 0..<m { B[r * m + c] -= factor * B[col * m + c] }
        }
    }
    var X = [Double](repeating: 0, count: n * m)
    for r in stride(from: n - 1, through: 0, by: -1) {
        for c in 0..<m {
            var s = B[r * m + c]
            for k in (r + 1)..<max(n, r + 1) { s -= A[r * n + k] * X[k * m + c] }
            X[r * m + c] = s / A[r * n + r]
        }
    }
    return X
}

/// Ordinary least squares via normal equations: minimise |D·p − y|² for each RHS column.
/// `design` is rows×k row-major, `targets` is rows×m row-major.
func leastSquares(design: [Double], rows: Int, k: Int, targets: [Double], m: Int) -> [Double]? {
    var ata = [Double](repeating: 0, count: k * k)
    var atb = [Double](repeating: 0, count: k * m)
    for r in 0..<rows {
        for i in 0..<k {
            let di = design[r * k + i]
            if di == 0 { continue }
            for j in 0..<k { ata[i * k + j] += di * design[r * k + j] }
            for c in 0..<m { atb[i * m + c] += di * targets[r * m + c] }
        }
    }
    return solveLinearSystem(ata, atb, n: k, rhsColumns: m)
}
