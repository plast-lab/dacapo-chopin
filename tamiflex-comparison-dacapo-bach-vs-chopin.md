# TamiFlex Reflection-Log Comparison — DaCapo-Bach vs DaCapo-Chopin

TamiFlex Play-Out reflective-call logs, **default** workload. One line per recorded reflective call site, so **lines ≈ reflective calls captured**.

- **DaCapo-Bach** — DaCapo 9.12 (Bach); `doop-benchmarks/dacapo-bach/<b>-tamiflex-default.log`.
- **DaCapo-Chopin** — DaCapo Chopin (2023), updated TamiFlex; `dacapo-chopin/<b>/<b>-tamiflex-default-jdk<N>.log` (JDK 25 except cassandra→11, h2o/tradebeans/tradesoap→17).

Only the **11 benchmarks in both suites** are compared. Same TamiFlex CSV and same reflective-op kinds in both, so count differences are **version-driven** (different subject versions/workloads), not tooling artifacts.

_Status: 11/11 DaCapo-Chopin logs captured._

| Benchmark | DaCapo-Bach | DaCapo-Chopin | Chopin/Bach | Dominant op shift (Bach → Chopin) |
| :-------- | ----------: | ------------: | ----------: | :-------------------------------- |
| avrora    |          69 |           156 |        2.3× | Method.getName 6→85               |
| batik     |         481 |           171 |        0.4× | Field.getName 89→4                |
| eclipse   |      12,830 |         9,709 |        0.8× | Field.getModifiers 7358→3111      |
| fop       |         790 |         1,665 |        2.1× | Method.getName 302→768            |
| h2        |         120 |           271 |        2.3× | Method.getName 9→95               |
| jython    |      24,039 |        66,853 |        2.8× | Method.getName 7117→23041         |
| luindex   |         113 |           537 |        4.8× | Field.getModifiers 0→161          |
| lusearch  |          84 |           415 |        4.9× | Method.getName 2→139              |
| pmd       |       1,239 |        45,399 |       36.6× | Method.getName 444→17420          |
| sunflow   |         421 |           263 |        0.6× | Method.getName 207→131            |
| xalan     |         834 |           907 |        1.1× | Method.getName 461→559            |

**Why they differ:** DaCapo-Bach is the 2009-era 9.12 suite; DaCapo-Chopin is the modern suite — newer library versions (batik 1.16, lucene 9.x, current h2/pmd/jython), different inputs, and a modern JDK. `Method.getName` dominates most shifts (framework/library metadata lookups), and pmd's ~37× jump is the 6.13→6.55 rewrite. Both logs record the same op kinds (`Class.forName`, `Constructor.newInstance`, `Method.invoke`, `Array.newInstance`, `Field.*`, ...).
