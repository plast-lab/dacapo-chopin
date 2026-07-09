#!/usr/bin/env bash
# =============================================================================
# capture-jacoco-dynamic-reachable.sh
#
# Capture the set of methods that ACTUALLY EXECUTE under each DaCapo-Chopin
# benchmark's DEFAULT workload, via JaCoCo, in two scopes:
#   <bench>/<bench>-jacoco-dynamic-reachable-app-libs.txt  (whole bundle: subject + deps)
#   <bench>/<bench>-jacoco-dynamic-reachable-app.txt       (subject packages only)
# Output is one Doop-format Soot signature per line, e.g.
#   <net.sourceforge.pmd.PMD: void main(java.lang.String[])>
#
# SCOPING (changed 2026-07): app+libs is JaCoCo coverage over ALL bundle jars
# (dacapo-chopin/<bench>/{app,libs}); app is the SUBJECT-PACKAGE SUBSET of that set,
# selected by the per-benchmark SUBJECT_RX regex below — NOT by which jars happen to
# live in app/. This is robust to how classes are split across app/ vs libs/ (e.g. a
# fat app jar bundling deps, or eclipse whose org.eclipse.jdt subject sits in libs/),
# so the "app" recall denominator always means the subject, wherever its classes live.
#
# HOW IT WORKS
#   1. Run <bench> once under the JaCoCo java-agent -> <bench>.exec (execution data).
#   2. `jacococli report` the .exec against ALL bundle class files -> app-libs.txt.
#   3. jacoco_to_soot.py -> covered methods (METHOD counter covered>=1) as signatures.
#   4. grep the SUBJECT_RX regex over app-libs.txt -> app.txt (the subject subset).
#
# WHY PER-BENCHMARK QUIRKS: most benchmarks run via the Chopin harness, but a few
# don't in a stock environment, so this script encodes the exact working recipe for
# each (see the RUN RECIPES section). All 22 were captured this way.
#
# PREREQUISITES
#   * A built DaCapo checkout ($DACAPO) with the incremental launcher jar
#     dacapo-evaluation-git-.jar; `ant <bench>` (JDK 8) registers a bench in it.
#   * JaCoCo 0.8.x agent + cli, and jacoco_to_soot.py  (see $AGENT/$CLI/$PARSE).
#   * JDK 8 (harness build), JDK 11 (most runs), JDK 17 (spring/tomcat/h2o/kafka).
#   * The dacapo-chopin bundle ($BUNDLE) providing per-bench app/ + libs/.
#   * For h2o & kafka: the dacapo-collect run trees (see H2O/KAFKA recipes) — these
#     carry a full runnable h2o.jar and a kafka launcher whose Class-Path already
#     lists ZooKeeper, which the stock incremental build does NOT produce.
#
# USAGE
#   ./capture-jacoco-dynamic-reachable.sh [bench ...]      # default: all 22
# =============================================================================
set -uo pipefail

# ---- configuration (edit paths for your machine) ----------------------------
DACAPO=/home/anantoni/dev/dacapobench/benchmarks
DIST="$DACAPO/dacapo-evaluation-git-.jar"          # incremental launcher (ant <bench> adds a bench)
BUNDLE=/home/anantoni/dev/dacapo-chopin   # per-bench app/ + libs/ (scope class files)
SCA_WORK=/tmp/sca/dacapo-dacapobench-d2afa96f      # dacapo-collect work dir (h2o/kafka run trees)

JT=/home/anantoni/dev/doop/jacoco-tools
AGENT="$JT/jacocoagent-runtime.jar"                # JaCoCo agent (runtime, org.jacoco.agent)
CLI="$JT/jacococli.jar"                            # JaCoCo CLI (jacococli.jar)
PARSE="$JT/jacoco_to_soot.py"                      # XML -> Doop Soot signatures

J8=/usr/lib/jvm/java-1.8.0-openjdk-amd64
J11=/home/anantoni/.sdkman/candidates/java/11.0.31-tem
J17=/home/anantoni/.sdkman/candidates/java/17.0.19-tem

STUB=/tmp/sca/dummy-bin                             # no-op shims (cvs/svn/git/...) the ant build calls
[ -d "$STUB" ] && export PATH="$STUB:$PATH"
EXECDIR=/tmp                                        # where <bench>.exec files live
say(){ printf '[jacoco] %s\n' "$*" >&2; }

# ---- report one scope from an exec ------------------------------------------
# report_scope <bench> <app|applibs> <outfile>
# Robust against (a) duplicate class names across lib jars and (b) multi-release
# (META-INF/versions) overlays: on a direct-report failure, MERGE all classes into
# one dir (first-wins dedup) and drop version overlays, then report against the dir.
report_scope(){
  local b=$1 scope=$2 out=$3
  local dirs=("$BUNDLE/$b/app"); [ "$scope" = applibs ] && dirs+=("$BUNDLE/$b/libs")
  local jars=() dir j; for dir in "${dirs[@]}"; do for j in "$dir"/*.jar; do [ -f "$j" ] && jars+=("$j"); done; done
  [ "${#jars[@]}" -eq 0 ] && { : > "$out"; echo 0; return 0; }
  local xml; xml=$(mktemp)
  local cf=(); for j in "${jars[@]}"; do cf+=(--classfiles "$j"); done
  if "$J11/bin/java" -jar "$CLI" report "$EXECDIR/jacoco-$b.exec" "${cf[@]}" --xml "$xml" >/dev/null 2>&1; then
    python3 "$PARSE" "$xml" > "$out"; rm -f "$xml"; wc -l < "$out"; return 0
  fi
  local md; md=$(mktemp -d)
  for j in "${jars[@]}"; do ( cd "$md" && unzip -nq "$j" '*.class' >/dev/null 2>&1 ); done
  rm -rf "$md/META-INF/versions" 2>/dev/null
  if "$J11/bin/java" -jar "$CLI" report "$EXECDIR/jacoco-$b.exec" --classfiles "$md" --xml "$xml" >/dev/null 2>&1; then
    python3 "$PARSE" "$xml" > "$out"; rm -f "$xml"; rm -rf "$md"; wc -l < "$out"; return 0
  fi
  rm -f "$xml"; rm -rf "$md"; echo "REPORT-FAIL"; return 1
}

# ---- subject-package regexes (the "app" scope) ------------------------------
# grep -E patterns anchored to a Soot signature's leading '<' (the declaring class
# starts right after it). Equivalent Doop --regex forms, for reference:
#   avrora   avrora.*:cck.*:jintgen.*
#   kafka    org.apache.kafka.*:kafka.*
#   h2o      water.*:hex.*:ai.h2o.*
#   spring   org.springframework.*
#   tomcat   org.apache.catalina.*:org.apache.coyote.*:org.apache.tomcat.*:org.apache.jasper.*:org.apache.el.*
#   xalan    org.apache.{xalan:xpath:xml.dtm:xml.res:xml.serializer:xml.utils}.*
# NOTE tradebeans/tradesoap: the DayTrader app deploys as an EAR inside WildFly, so its
# classes are NOT in the stock app/libs jars. daytrader-app.jar (the javaee6 app classes,
# extracted from daytrader-ear-3.0-SNAPSHOT.ear) has been added to each app/ so the app
# scope is non-empty; the rest of the executed set is the WildFly/JBoss server.
declare -A SUBJECT_RX=(
  [avrora]='^<(avrora|cck|jintgen)\.'
  [batik]='^<org\.apache\.batik\.'
  [biojava]='^<org\.biojava\.nbio\.'
  [cassandra]='^<org\.apache\.cassandra\.'
  [eclipse]='^<org\.eclipse\.jdt\.'
  [fop]='^<org\.apache\.fop\.'
  [graphchi]='^<edu\.cmu\.graphchi\.'
  [h2]='^<org\.h2\.'
  [h2o]='^<(water|hex|ai\.h2o)\.'
  [jme]='^<com\.jme3\.'
  [jython]='^<org\.python\.'
  [kafka]='^<(org\.apache\.kafka|kafka)\.'
  [luindex]='^<org\.apache\.lucene\.'
  [lusearch]='^<org\.apache\.lucene\.'
  [pmd]='^<net\.sourceforge\.pmd\.'
  [spring]='^<org\.springframework\.'
  [sunflow]='^<org\.sunflow\.'
  [tomcat]='^<org\.apache\.(catalina|coyote|tomcat|jasper|el)\.'
  [tradebeans]='^<org\.apache\.geronimo\.daytrader\.'
  [tradesoap]='^<org\.apache\.geronimo\.daytrader\.'
  [xalan]='^<org\.apache\.(xalan|xpath|xml\.dtm|xml\.res|xml\.serializer|xml\.utils)\.'
  [zxing]='^<com\.google\.zxing\.'
)

emit_both(){ # emit_both <bench> ; requires $EXECDIR/jacoco-<bench>.exec
  local b=$1; mkdir -p "$BUNDLE/$b"
  local appf="$BUNDLE/$b/$b-jacoco-dynamic-reachable-app.txt"
  local libf="$BUNDLE/$b/$b-jacoco-dynamic-reachable-app-libs.txt"
  # app+libs = full bundle coverage (one report over all app/ + libs/ jars)
  report_scope "$b" applibs "$libf" >/dev/null
  # drop DaCapo harness glue (org.dacapo.*) so the driver never inflates any scope;
  # harness jars are also removed from the bundle, this is a belt-and-braces filter.
  grep -vE '^<org\.dacapo\.' "$libf" | sort -u > "$libf.tmp" && mv "$libf.tmp" "$libf"
  local l; l=$(wc -l < "$libf" | tr -d ' ')
  # app = subject-package subset of that executed set (regex-selected, jar-placement-agnostic)
  local a rx="${SUBJECT_RX[$b]:-}"
  if [ -n "$rx" ]; then
    grep -E "$rx" "$libf" | sort -u > "$appf"; a=$(wc -l < "$appf" | tr -d ' ')
  else
    a=$(report_scope "$b" app "$appf")   # fallback: jar-based, if no subject regex defined
    say "$b: WARNING no SUBJECT_RX -> app scope fell back to app/-jar membership"
  fi
  say "$b: app=$a  app+lib=$l"
}

# =============================================================================
# RUN RECIPES — produce $EXECDIR/jacoco-<bench>.exec, then call emit_both
# =============================================================================

# (A) Chopin harness benchmarks: ant build (JDK 8) then run under the JaCoCo agent
#     (JDK 11 by default; JDK 17 for spring/tomcat). Gate on DaCapo printing PASSED.
run_harness(){ # run_harness <bench> <run-jdk>
  local b=$1 RJ=$2
  ( cd "$DACAPO" && JAVA_HOME=$J8 timeout 1800 ant "$b" >/tmp/jbuild-$b.log 2>&1; rm -rf scratch out )
  rm -f "$EXECDIR/jacoco-$b.exec"
  ( cd "$DACAPO" && timeout 3600 "$RJ/bin/java" \
      -javaagent:"$AGENT=destfile=$EXECDIR/jacoco-$b.exec,output=file,dumponexit=true" \
      -jar "$DIST" -s default "$b" >/tmp/jrun-$b.log 2>&1 )
  [ "$(grep -aoE 'PASSED|FAILED' /tmp/jrun-$b.log | tail -1)" = PASSED ] && [ -s "$EXECDIR/jacoco-$b.exec" ]
}

# (B) pmd: harness ships 6.13.0 but the bundle is 6.55.0, so run pmd STANDALONE at
#     6.55.0 with pmd.cnf's `size default` ruleset so R_d matches the 6.55.0 classes.
run_pmd(){
  local PCP; PCP=$(echo "$BUNDLE/pmd/app/"*.jar "$BUNDLE/pmd/libs/"*.jar | tr ' ' ':')
  local PSRC="$DACAPO/bms/pmd/data/dat/pmd/pmd-core"
  local RULES="java-basic,java-braces,java-clone,java-codesize,java-comments,java-controversial,java-design,java-empty,java-finalizers,java-imports,java-naming,java-optimizations"
  rm -f "$EXECDIR/jacoco-pmd.exec"
  timeout 3600 "$J8/bin/java" -javaagent:"$AGENT=destfile=$EXECDIR/jacoco-pmd.exec" -cp "$PCP" \
    net.sourceforge.pmd.PMD -d "$PSRC" -t "$(nproc)" -f text -language java -shortnames \
    -failOnViolation false -rulesets "$RULES" -r /tmp/pmd-jacoco-report.txt >/tmp/jrun-pmd.log 2>&1
  [ -s "$EXECDIR/jacoco-pmd.exec" ]
}

# (C) biojava: Chopin harness NPEs (URL.toURI() null). Run the AAProperties main
#     STANDALONE with biojava.cnf's exact `size default` input (the harness only wraps
#     this same main). Input lives in the biojava-data.zip download.
run_biojava(){
  local FAT="$BUNDLE/biojava/app/AAProperties-jar-with-dependencies.jar"
  local ZIP="$DACAPO/bms/biojava/downloads/biojava-data.zip"
  local ENTRY; ENTRY=$(unzip -Z1 "$ZIP" | grep -i 'gold_strains.*fasta' | head -1)
  mkdir -p /tmp/sca/biojava-run && ( cd /tmp/sca/biojava-run && unzip -oq "$ZIP" "$ENTRY" )
  rm -f "$EXECDIR/jacoco-biojava.exec"
  timeout 1800 "$J11/bin/java" -javaagent:"$AGENT=destfile=$EXECDIR/jacoco-biojava.exec" \
    -jar "$FAT" -i "/tmp/sca/biojava-run/$ENTRY" -o /tmp/sca/biojava-run/biojava.out -a >/tmp/jrun-biojava.log 2>&1
  [ -s "$EXECDIR/jacoco-biojava.exec" ]
}

# (D) h2o: the stock harness build re-runs h2o's own gradlew (needs node/npm/R) and
#     fails. Instead run from the dacapo-collect RUN TREE, which has a full runnable
#     h2o.jar + a launcher (Main-Class Harness, full Class-Path) + the citibike data.
#     Needs -Xmx (default heap/GC chokes mid model-build) and JDK 17 (Add-Opens +
#     -Djava.security.manager=allow).
run_h2o(){
  local RT="$SCA_WORK/h2o/run/dacapo-evaluation-git-e947cbfc"
  [ -f "$RT/launchers/h2o.jar" ] || { say "h2o: no collect run tree at $RT (rebuild via dacapo-collect.sh)"; return 1; }
  rm -f "$EXECDIR/jacoco-h2o.exec"
  ( cd "$RT/launchers" && timeout 3600 "$J17/bin/java" -Xmx64g \
      -javaagent:"$AGENT=destfile=$EXECDIR/jacoco-h2o.exec,output=file,dumponexit=true" \
      -Djava.security.manager=allow -jar h2o.jar -s default h2o >/tmp/jrun-h2o.log 2>&1 )
  [ "$(grep -aoE 'PASSED|FAILED' /tmp/jrun-h2o.log | tail -1)" = PASSED ] && [ -s "$EXECDIR/jacoco-h2o.exec" ]
}

# (E) kafka: the stock incremental build's kafka launcher omits ZooKeeper from its
#     Class-Path (-> ClassNotFoundException ZooKeeperServerMain), and forcing it via
#     -Xbootclasspath cascades (boot loader can't see the app loader's slf4j/metrics).
#     The dacapo-collect run tree's launcher ALREADY lists zookeeper+jute (in the same
#     isolated classloader as slf4j/netty/metrics), so run from there. JDK 17.
run_kafka(){
  local RT="$SCA_WORK/kafka/run/dacapo-evaluation-git-e947cbfc"
  [ -f "$RT/launchers/kafka.jar" ] || { say "kafka: no collect run tree at $RT (rebuild via dacapo-collect.sh)"; return 1; }
  rm -f "$EXECDIR/jacoco-kafka.exec"
  ( cd "$RT/launchers" && timeout 3600 "$J17/bin/java" \
      -javaagent:"$AGENT=destfile=$EXECDIR/jacoco-kafka.exec,output=file,dumponexit=true" \
      -Djava.security.manager=allow -jar kafka.jar -s default kafka >/tmp/jrun-kafka.log 2>&1 )
  [ "$(grep -aoE 'PASSED|FAILED' /tmp/jrun-kafka.log | tail -1)" = PASSED ] && [ -s "$EXECDIR/jacoco-kafka.exec" ]
}

# ---- per-benchmark dispatch -------------------------------------------------
capture(){
  local b=$1 ok=1
  case "$b" in
    # Chopin harness, JDK 11
    avrora|batik|fop|graphchi|jme|jython|sunflow|xalan|zxing|h2|luindex|lusearch|eclipse|cassandra)
      run_harness "$b" "$J11"; ok=$? ;;
    # Chopin harness, JDK 17
    spring|tomcat|tradebeans|tradesoap)
      run_harness "$b" "$J17"; ok=$? ;;
    pmd)      run_pmd;      ok=$? ;;
    biojava)  run_biojava;  ok=$? ;;
    h2o)      run_h2o;      ok=$? ;;
    kafka)    run_kafka;    ok=$? ;;
    *) say "$b: unknown benchmark"; return 2 ;;
  esac
  if [ "$ok" -eq 0 ]; then emit_both "$b"; else say "$b: RUN FAILED (see /tmp/jrun-$b.log)"; return 1; fi
}

ALL="avrora batik biojava cassandra eclipse fop graphchi h2 h2o jme jython kafka luindex lusearch pmd spring sunflow tomcat tradebeans tradesoap xalan zxing"
BENCHES="${*:-$ALL}"
for b in $BENCHES; do capture "$b"; done
say "done."
