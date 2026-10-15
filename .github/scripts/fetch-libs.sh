#!/usr/bin/env bash
# CI 依赖拉取：mixin、FML loader、neoforge universal、slf4j（公共 Maven Central / NeoForged maven）
set -euo pipefail
mkdir -p build/libs
cd build/libs

# SpongePowered Mixin 0.8.5 (Sponge repo, not on Maven Central)
curl -sfLO https://repo.spongepowered.org/repository/maven-public/org/spongepowered/mixin/0.8.5/mixin-0.8.5.jar || echo "WARN: mixin fetch failed"
# SLF4J API 2.0.7
curl -sfLO https://repo1.maven.org/maven2/org/slf4j/slf4j-api/2.0.7/slf4j-api-2.0.7.jar
# NeoForged FML loader 4.0.45
curl -sfLO https://maven.neoforged.net/releases/net/neoforged/fancymodloader/loader/4.0.45/loader-4.0.45.jar
# NeoForged legacy API jar (provides net.neoforged.api.distmarker.Dist - required for compiling)
curl -sfLO https://maven.neoforged.net/releases/net/neoforged/mergetool/2.0.0/mergetool-2.0.0-api.jar
# NeoForge universal 21.1.248
curl -sfLO https://maven.neoforged.net/releases/net/neoforged/neoforge/21.1.248/neoforge-21.1.248-universal.jar

cd ..
echo -n "" > cp.txt
first=1
for f in libs/*.jar; do
  if [ $first -eq 1 ]; then
    printf '%s' "$PWD/$f" > cp.txt
    first=0
  else
    printf ':%s' "$PWD/$f" >> cp.txt
  fi
done
echo "Classpath: $(cat cp.txt)"
