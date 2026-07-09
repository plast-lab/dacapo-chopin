# JaCoCo Dynamic-Reachability — DaCapo-Chopin

Methods that actually executed under the **default** DaCapo workload (JaCoCo, covered-only).
Two scopes per benchmark: **app** = subject packages, **app+lib** = whole bundle (subject + deps).
Files: `<bench>/<bench>-jacoco-dynamic-reachable-{app,app-libs}.txt` (Doop-format Soot signatures).

**app scope is regex-based (updated 2026-07).** `app` is now the subset of the executed set
whose declaring class matches the benchmark's subject regex (see `scripts/capture-jacoco-dynamic-reachable.sh`
`SUBJECT_RX`), **not** the classes that happen to sit in `app/`. This makes `app` mean the true
subject regardless of where its classes physically live — correct after the fat-jar split (deps
moved to `libs/`) and for eclipse, whose `org.eclipse.jdt` subject lives in `libs/`.

**DaCapo harness glue removed (updated 2026-07).** The per-benchmark driver jars (`org.dacapo.*`)
were deleted from the bundle and `org.dacapo.*` methods stripped from every set, so the DaCapo
harness no longer inflates any `app+lib` count. **tradebeans/tradesoap fixed:** the DayTrader
app (`org.apache.geronimo.daytrader.javaee6.*`) deploys as an EAR inside WildFly and was missing
from the bundle; `daytrader-app.jar` (extracted from the EAR) was added to each `app/`, so their
`app` scope is now non-empty.

```
Benchmark    App methods dynamic reachable  App+lib methods dynamic reachable
------------ -----------------------------  ---------------------------------
avrora       1435                           1435                          
batik        2001                           2007                          
biojava      117                            1285                          
cassandra    10114                          21114                         
eclipse      8708                           14999                         
fop          5926                           9550                          
graphchi     165                            346                           
h2           2420                           2557                          
h2o          3848                           9271                          
jme          1175                           1221                          
jython       5805                           7170                          
kafka        8176                           17143                         
luindex      2595                           2595                          
lusearch     1445                           1445                          
pmd          4190                           6356                          
spring       11728                          31193                         
sunflow      551                            551                           
tomcat       5285                           9399                          
tradebeans   203                            52943                         
tradesoap    207                            56651                         
xalan        1622                           2206                          
zxing        863                            1034                          
------------ -----------------------------  ---------------------------------
TOTAL (22)   78579                          252471                        
```

Subject regexes used (Doop `--regex` form):

```
avrora    avrora.*:cck.*:jintgen.*                        luindex   org.apache.lucene.*
batik     org.apache.batik.*                              lusearch  org.apache.lucene.*
biojava   org.biojava.nbio.*                              pmd       net.sourceforge.pmd.*
cassandra org.apache.cassandra.*                          spring    org.springframework.*
eclipse   org.eclipse.jdt.*                               sunflow   org.sunflow.*
fop       org.apache.fop.*                                tomcat    org.apache.{catalina:coyote:tomcat:jasper:el}.*
graphchi  edu.cmu.graphchi.*                              xalan     org.apache.{xalan:xpath:xml.dtm:xml.res:xml.serializer:xml.utils}.*
h2        org.h2.*                                        zxing     com.google.zxing.*
h2o       water.*:hex.*:ai.h2o.*                          jme       com.jme3.*
kafka     org.apache.kafka.*:kafka.*                      trade*    org.apache.geronimo.daytrader.*
```

_All 22 benchmarks captured._

_**tradebeans / tradesoap.** The DayTrader app (`org.apache.geronimo.daytrader.javaee6.*`) deploys
as an EAR inside WildFly and wasn't in the bundle; `daytrader-app.jar` (extracted from the EAR) was
added to each `app/`, giving app = 203/207. The remaining ~52–56 k app+lib methods are the
WildFly/JBoss server the benchmark drives._

_**DaCapo harness removed.** Driver jars (`dacapo-<bench>.jar`, the DayTrader driver, and the
`org.dacapo` classes inside eclipse's glue jar) were deleted from the bundle and `org.dacapo.*`
stripped from every set — so the harness no longer counts toward any app+lib total. Effect:
eclipse −5, h2 −44, kafka −18, luindex −3, lusearch −7, spring −11, tomcat −36, xalan −7._

_**Ties (app = app+lib):** avrora (no lib jars), sunflow (its janino lib + default-package
`SunflowGUI` never run), and now luindex/lusearch (their only non-subject executed code was the
harness glue, now removed)._

_**Notable corrections vs the earlier jar-based scope:** biojava 1285→117, graphchi 346→165,
zxing 1034→863 (old counts included deps bundled in the fat app jar); eclipse 2295→8708 (old
scope measured the OSGi launcher jar, not the `jdt` subject in `libs/`); h2o 9078→3848 (real
`water`/`hex`/`ai.h2o` subject vs the whole fat jar); pmd −47 (jaxen), tomcat −93
(`org.apache.naming`), spring −18 (commons-logging/aopalliance), kafka +168 (kafka classes that
sat in lib jars)._
