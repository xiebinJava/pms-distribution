#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="${PMS_BACKEND_REPO:-$ROOT/../pms-backend}"
FRONT="${PMS_FRONT_REPO:-$ROOT/../pms-front}"
[[ -d "$BACKEND" ]] || { echo "backend repository not found; set PMS_BACKEND_REPO" >&2; exit 1; }
[[ -d "$FRONT" ]] || { echo "frontend repository not found; set PMS_FRONT_REPO" >&2; exit 1; }
ruby -ryaml -e '
def check(path, images)
 d=YAML.load_file(path); on=d[true]||d["on"]
 abort "triggers" unless on.keys.sort==["push","workflow_dispatch"] && on["push"]["tags"]==["v*.*.*"] && on["workflow_dispatch"]["inputs"]["verify_anonymous"]["default"]==false
 abort "permissions" unless d["permissions"]["packages"]=="write"
 s=d["jobs"]["publish"]["steps"]; l=s.find{|x|x["uses"]=="docker/login-action@v3"}; abort "login" unless l&&l.dig("with","registry")=="ghcr.io"&&l.dig("with","password")=="${{ secrets.GITHUB_TOKEN }}"
 q=s.index{|x|x["uses"]=="docker/setup-qemu-action@v3"}; b=s.index{|x|x["uses"]=="docker/setup-buildx-action@v3"}; abort "order" unless q&&b&&q<b
 images.each{|image,file| a=s.select{|x|x["uses"]=="docker/build-push-action@v6"&&x.dig("with","tags").include?(image)}; abort "build" unless a.length==1; w=a[0]["with"]; abort "fields" unless w["context"]=="."&&w["file"]==file&&w["platforms"]=="linux/amd64,linux/arm64"&&w["push"]==true&&w["tags"].include?("${{ steps.version.outputs.version }}")&&w["tags"].include?("${{ github.sha }}") }
 p=s.find{|x|x["name"]=~/Refuse existing version tag/}; abort "preflight" unless p&&p["run"].include?("imagetools inspect")&&p["run"].include?("for tag")&&p["run"].include?("${{ steps.version.outputs.version }}")&&p["run"].include?("sha-${{ github.sha }}")&&p["run"].include?("refusing to overwrite"); images.each_key{|image| abort "preflight image #{image}" unless p["run"].include?(image) }
 v=s.find{|x|x["name"]=="Verify anonymous package access"}; abort "anonymous" unless v&&v["if"]=="github.event_name == '\''push'\'' || inputs.verify_anonymous"
end
check(ARGV[0],{"pms-backend"=>"Dockerfile"});check(ARGV[1],{"pms-front"=>"Dockerfile"})
' "$BACKEND/.github/workflows/publish-images.yml" "$FRONT/.github/workflows/publish-image.yml"
echo "Release workflow contracts passed"
