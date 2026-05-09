#!/usr/bin/env sh
set -eu

skill_dir="resources/skills/lazycat-movie-search"

rm -rf "$skill_dir"
mkdir -p "$skill_dir"

cp SKILL.md "$skill_dir/SKILL.md"
cp -R agents "$skill_dir/agents"
cp -R scripts "$skill_dir/scripts"

chmod +x "$skill_dir/scripts/"*.sh

mkdir -p dist
