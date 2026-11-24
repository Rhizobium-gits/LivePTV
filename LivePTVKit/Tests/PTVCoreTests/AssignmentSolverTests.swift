import Foundation
import Testing
@testable import PTVCore

@Suite struct AssignmentSolverTests {
    /// 🐱 Random sparse problems against exhaustive enumeration: the sparse shortest-augmenting-path solver must reach
    /// 🐱 the minimum total cost (unmatched rows cost `missCost`), using each column at most once.
    @Test func matchesBruteForceMinimum() {
        var rng = Synth(state: 31)
        for _ in 0..<300 {
            let rows = 1 + Int(rng.unit() * 6), cols = 1 + Int(rng.unit() * 6)
            var edges: [[(Int, Double)]] = []
            var solver = AssignmentSolver()
            solver.begin(rows: rows, columns: cols)
            for _ in 0..<rows {
                var e: [(Int, Double)] = []
                for c in 0..<cols where rng.unit() < 0.5 {
                    let cost = rng.unit()
                    e.append((c, cost))
                    solver.addEdge(column: c, cost: cost)
                }
                edges.append(e)
                solver.endRow()
            }
            let missCost = 0.3 + rng.unit()
            let match = solver.solve(missCost: missCost, maxGroupSize: 1000)

            var total = 0.0
            var used = Set<Int>()
            for r in 0..<rows {
                if match[r] < 0 { total += missCost; continue }
                let e = edges[r].first { $0.0 == match[r] }
                #expect(e != nil)
                #expect(!used.contains(match[r]))
                used.insert(match[r])
                total += e?.1 ?? .infinity
            }

            var best = Double.infinity
            func search(_ r: Int, _ taken: Set<Int>, _ cost: Double) {
                if r == rows { best = min(best, cost); return }
                search(r + 1, taken, cost + missCost)
                for (c, w) in edges[r] where !taken.contains(c) { search(r + 1, taken.union([c]), cost + w) }
            }
            search(0, [], 0)
            #expect(abs(total - best) < 1e-9, "solver \(total), optimum \(best)")
        }
    }

    /// 🐱 Groups larger than the limit are assigned closest-first (a valid matching, not the minimum).
    @Test func oversizedGroupsFallBackToClosestFirst() {
        func solve(_ limit: Int) -> [Int] {
            var solver = AssignmentSolver()
            solver.begin(rows: 2, columns: 2)
            solver.addEdge(column: 0, cost: 0.1); solver.addEdge(column: 1, cost: 0.2); solver.endRow()
            solver.addEdge(column: 0, cost: 0.15); solver.endRow()
            return solver.solve(missCost: 1, maxGroupSize: limit)
        }
        #expect(solve(3) == [0, -1])     // 🐱 closest-first: 0.1 + 1 (row 1 unmatched)
        #expect(solve(4) == [1, 0])      // 🐱 exact: 0.2 + 0.15
    }
}
