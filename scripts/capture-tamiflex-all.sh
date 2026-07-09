#!/usr/bin/env bash
# =============================================================================
# capture-tamiflex-all.sh
#
# Capture TamiFlex Play-Out reflection traces (refl.log) for all 22 DaCapo-Chopin
# benchmarks under their DEFAULT workload, one file per benchmark:
#   <bench>/<bench>-tamiflex-default-jdk<N>.log   (Doop-format reflection log)
# where <N> is the JDK the benchmark actually ran on.
#
# HOW IT WORKS
#   Run each benchmark under the TamiFlex Play-Out agent (-javaagent:poa.jar). The
#   agent (configured by ~/.tamiflex/poa.properties: dontDumpClasses=true,
#   dontNormalize=true) writes refl.log to <cwd>/out/refl.log. We rm the out/ dir
#   before each run (TamiFlex appends -> stale entries would contaminate otherwise),
#   run, then copy <cwd>/out/refl.log to the benchmark's folder.
#
# JDK POLICY
#   Prefer JDK 25 (the updated TamiFlex + its ASM 9.8 understand class-file major 69).
#   A few benchmarks don't RUN on 25 (SecurityManager removed in JDK 24+, or older
#   deps), so we fall back per benchmark: cassandra->11, h2o/tradebeans/tradesoap->17.
#   The filename records the JDK that actually produced the log.
#
# PREREQUISITES
#   * The FIXED Play-Out agent jar ($POA) built from the updated TamiFlex:
#       cd <tamiflex> && ./gradlew :playout-agent:jar   (JDK 21)
#     (fixes: JDK9+ lambda/hidden-class name normalization; resolver falls back to
#      the caller's Method instead of throwing on reflection-filtered targets like
#      sun.misc.Unsafe.getUnsafe — without these, jython/cassandra/... abort.)
#   * ~/.tamiflex/poa.properties with dontDumpClasses=true, dontNormalize=true.
#   * A built DaCapo Chopin checkout ($DACAPO); `ant <bench>` (JDK 8) registers a
#     benchmark into the incremental launcher jar dacapo-evaluation-git-.jar.
#   * JDK 8 (harness build), 11, 17, 25 via SDKMAN (paths below).
#   * The per-benchmark app/libs bundles under $BUNDLE (for pmd/biojava standalone).
#   * For h2o & kafka: the dacapo-collect run trees under $SCA_WORK (full runnable
#     jar + launcher whose Class-Path already carries the deps incl. ZooKeeper).
#
# USAGE
#   ./capture-tamiflex-all.sh [bench ...]        # default: all 22
# =============================================================================
set -uo pipefail

# ---- configuration (edit for your machine) ----------------------------------
POA=/home/anantoni/dev/tamiflex/PlayOutAgent/build/libs/poa.jar
J8=/usr/lib/jvm/java-1.8.0-openjdk-amd64
declare -A JDK=( [11]=/home/anantoni/.sdkman/candidates/java/11.0.31-tem
                 [17]=/home/anantoni/.sdkman/candidates/java/17.0.19-tem
                 [23]=/home/anantoni/.sdkman/candidates/java/23.0.2-oracle
                 [25]=/home/anantoni/.sdkman/candidates/java/25.0.2-oracle )
DACAPO=/home/anantoni/dev/dacapobench/benchmarks
DIST="$DACAPO/dacapo-evaluation-git-.jar"
BUNDLE=/home/anantoni/dev/dacapo-chopin
SCA_WORK=/tmp/sca/dacapo-dacapobench-d2afa96f    # dacapo-collect work dir (h2o/kafka run trees)
STUB=/tmp/sca/dummy-bin                           # no-op shims (cvs/svn/...) the ant build calls
[ -d "$STUB" ] && export PATH="$STUB:$PATH"
say(){ printf '[tamiflex] %s\n' "$*" >&2; }

clean_old(){ rm -f "$BUNDLE/$1/$1-tamiflex-default-jdk"*.log; }
passed(){ [ "$(grep -aoE 'PASSED|FAILED' "$1" 2>/dev/null | tail -1)" = PASSED ]; }
grab(){ # <bench> <rundir> <jdk>
  local b=$1 rd=$2 v=$3 out="$BUNDLE/$b/$b-tamiflex-default-jdk$v.log"
  [ -s "$rd/out/refl.log" ] || return 1
  mkdir -p "$BUNDLE/$b"; cp -f "$rd/out/refl.log" "$out"
  say "OK $b: $(wc -l < "$out") reflective calls (jdk$v)"
}

# (A) Chopin harness: ant build (JDK 8) + run under the agent. $3 = extra harness args
#     (e.g. tradesoap needs "-f 20": 20x timeout dilation to beat its 125s SOAP watchdog
#     under agent overhead).
do_harness(){ # <bench> <jdk-version> [extra-harness-args]
  local b=$1 v=$2 J=${JDK[$2]} extra=${3:-}
  ( cd "$DACAPO" && JAVA_HOME=$J8 timeout 1800 ant "$b" >/tmp/tf-build-$b.log 2>&1; rm -rf scratch out )
  ( cd "$DACAPO" && timeout 5400 "$J/bin/java" -javaagent:"$POA" -jar "$DIST" $extra -s default "$b" >/tmp/tf-run-$b-$v.log 2>&1 )
  passed "/tmp/tf-run-$b-$v.log" && grab "$b" "$DACAPO" "$v"
}
# (B) pmd: harness ships 6.13; the bundle is 6.55, so run pmd standalone at 6.55 with
#     pmd.cnf's default ruleset so the log matches the analyzed classes.
do_pmd(){ # <jdk-version>
  local v=$1 J=${JDK[$1]} rd="$SCA_WORK/tf-pmd"; rm -rf "$rd"; mkdir -p "$rd"
  local PCP; PCP=$(echo "$BUNDLE/pmd/app/"*.jar "$BUNDLE/pmd/libs/"*.jar | tr ' ' ':')
  local PSRC="$DACAPO/bms/pmd/data/dat/pmd/pmd-core"
  local RULES="java-basic,java-braces,java-clone,java-codesize,java-comments,java-controversial,java-design,java-empty,java-finalizers,java-imports,java-naming,java-optimizations"
  ( cd "$rd" && timeout 3600 "$J/bin/java" -javaagent:"$POA" -cp "$PCP" net.sourceforge.pmd.PMD -d "$PSRC" \
      -t "$(nproc)" -f text -language java -shortnames -failOnViolation false -rulesets "$RULES" -r "$rd/o.txt" >/tmp/tf-run-pmd-$v.log 2>&1 )
  grab pmd "$rd" "$v"
}
# (C) biojava: Chopin harness NPEs; run the AAProperties main standalone with biojava.cnf's
#     exact default-size input (from biojava-data.zip). Fat jar (deps bundled) => libs empty.
do_biojava(){ # <jdk-version>
  local v=$1 J=${JDK[$1]} rd="$SCA_WORK/tf-biojava"; rm -rf "$rd"; mkdir -p "$rd"
  local FAT="$BUNDLE/biojava/app/AAProperties-jar-with-dependencies.jar"
  local ZIP="$DACAPO/bms/biojava/downloads/biojava-data.zip"
  local ENTRY; ENTRY=$(unzip -Z1 "$ZIP" | grep -i 'gold_strains.*fasta' | head -1)
  ( cd "$rd" && unzip -oq "$ZIP" "$ENTRY" )
  ( cd "$rd" && timeout 1800 "$J/bin/java" -javaagent:"$POA" -jar "$FAT" -i "$rd/$ENTRY" -o "$rd/o" -a >/tmp/tf-run-biojava-$v.log 2>&1 )
  grab biojava "$rd" "$v"
}
# (D) h2o & (E) kafka: run from the dacapo-collect run tree (full runnable jar + launcher
#     with the complete Class-Path). The stock incremental build can't produce these
#     (h2o re-runs its own gradlew; kafka's launcher omits ZooKeeper).
do_runtree(){ # <bench> <jdk-version> <extra-jvm-args>
  local b=$1 v=$2 extra=$3 J=${JDK[$2]} RT="$SCA_WORK/$b/run/dacapo-evaluation-git-e947cbfc"
  [ -f "$RT/launchers/$b.jar" ] || { say "$b: no dacapo-collect run tree at $RT"; return 1; }
  ( cd "$RT/launchers" && rm -rf out && timeout 3600 "$J/bin/java" $extra -javaagent:"$POA" -jar "$b.jar" -s default "$b" >/tmp/tf-run-$b-$v.log 2>&1 )
  passed "/tmp/tf-run-$b-$v.log" && grab "$b" "$RT/launchers" "$v"
}

capture(){ # dispatch + JDK fallbacks
  local b=$1; clean_old "$b"; say "[$b] ..."
  case "$b" in
    pmd)        do_pmd 25 || do_pmd 17 || do_pmd 11 || say "FAIL $b" ;;
    biojava)    do_biojava 25 || do_biojava 17 || do_biojava 11 || say "FAIL $b" ;;
    kafka)      do_runtree kafka 25 "" || do_runtree kafka 17 "-Djava.security.manager=allow" || say "FAIL $b" ;;
    h2o)        do_runtree h2o 17 "-Xmx64g -Djava.security.manager=allow" || do_runtree h2o 23 "-Xmx64g -Djava.security.manager=allow" || say "FAIL $b" ;;
    tradesoap)  do_harness tradesoap 25 "-f 20" || do_harness tradesoap 17 "-f 20" || do_harness tradesoap 11 "-f 20" || say "FAIL $b" ;;
    cassandra|jython|tradebeans) do_harness "$b" 25 || do_harness "$b" 17 || do_harness "$b" 11 || say "FAIL $b" ;;
    *)          do_harness "$b" 25 || do_harness "$b" 17 || say "FAIL $b" ;;
  esac
}

ALL="avrora batik biojava cassandra eclipse fop graphchi h2 h2o jme jython kafka luindex lusearch pmd spring sunflow tomcat tradebeans tradesoap xalan zxing"
for b in ${*:-$ALL}; do capture "$b"; done
say "done."
