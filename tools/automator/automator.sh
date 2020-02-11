#!/usr/bin/env bash

# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

print_error_and_exit() {
  {
    echo
    echo "$1"
    exit "${2:-1}"
  } >&2
}

cleanup() {
  rm -rf "${tmp_dir:-}" "${tmp_token:-}" "${tmp_script:-}" "${tmp_git:-}"
}

get_opts() {
  if opt="$(getopt -o i -l branch:,sha:,org:,repo:,title:,match-title:,body:,user:,email:,modifier:,script-path:,cmd:,token-path:,token: -n "$(basename "$0")" -- "$@")"; then
    eval set -- "$opt"
  else
    print_error_and_exit "unable to parse options"
  fi

  while true; do
    case "$1" in
    --branch)
      branch="$2"
      shift 2
      ;;
    --sha)
      sha="$2"
      sha_short="$(echo "$2" | cut -c1-7)"
      shift 2
      ;;
    --org)
      org="$2"
      shift 2
      ;;
    --repo)
      repos="$2"
      shift 2
      ;;
    --title)
      title_tmpl="$2"
      shift 2
      ;;
    --match-title)
      match_title_tmpl="$2"
      shift 2
      ;;
    --body)
      body_tmpl="$2"
      shift 2
      ;;
    --user)
      user="$2"
      shift 2
      ;;
    --email)
      email="$2"
      shift 2
      ;;
    --modifier)
      modifier="$2"
      shift 2
      ;;
    --script-path)
      script_path="$2"
      shift 2
      ;;
    --cmd)
      tmp_script="$(mktemp -t script-XXXXXXXXXX)"
      echo "$2" >"$tmp_script"
      script_path="$tmp_script"
      shift 2
      ;;
    --token-path)
      token_path="$2"
      token="$(cat "$token_path")"
      shift 2
      ;;
    --token)
      token="$2"
      tmp_token="$(mktemp -t token-XXXXXXXXXX)"
      echo "$token" >"$tmp_token"
      token_path="$tmp_token"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      print_error_and_exit "unknown option: $1"
      ;;
    esac
  done
}

validate_opts() {
  if [ -z "${branch:-}" ]; then
    branch="$(git describe --contains --all HEAD)"
  fi

  if [ -z "${sha:-}" ]; then
    sha="$(git rev-parse HEAD)"
    sha_short="$(git rev-parse --short HEAD)"
  fi

  if [ -z "${title_tmpl:-}" ]; then
    # shellcheck disable=SC2016
    # This is intentionally evaluated in a child process.
    title_tmpl='Automator: update $AUTOMATOR_ORG/$AUTOMATOR_REPO@$AUTOMATOR_BRANCH-$AUTOMATOR_MODIFIER'
  fi

  if [ -z "${match_title_tmpl:-}" ]; then
    match_title_tmpl="$title_tmpl"
  fi

  if [ -z "${body_tmpl:-}" ]; then
    # shellcheck disable=SC2016
    # This is intentionally evaluated in a child process.
    body_tmpl='Generated by Automator - $(date -uIseconds)'
  fi

  if [ -z "${org:-}" ]; then
    print_error_and_exit "org is a required option"
  fi

  if [ -z "${repos:-}" ]; then
    print_error_and_exit "repo is a required option"
  fi
  IFS=',' read -r -a repos <<<"$repos"

  if [ ! -f "${token_path:-}" ] || [ -z "${token:-}" ]; then
    print_error_and_exit "token_path or token is a required option"
  fi

  if [ ! -f "$script_path" ]; then
    print_error_and_exit "script-path or cmd is a required option"
  fi

  if [ -z "${modifier:-}" ]; then
    modifier="automator"
  fi

  if [ -z "${user:-}" ]; then
    user="$(curl --silent --header "Authorization: token $token" "https://api.github.com/user" | jq --raw-output ".login")"
  fi

  if [ -z "${email:-}" ]; then
    email="$(curl --silent --header "Authorization: token $token" "https://api.github.com/user" | jq --raw-output ".email")"
  fi
}

evaluate_opts() {
  export AUTOMATOR_ORG="$org" AUTOMATOR_REPO="$repo" AUTOMATOR_BRANCH="$branch" AUTOMATOR_SHA="$sha" AUTOMATOR_SHA_SHORT="$sha_short" AUTOMATOR_MODIFIER="$modifier"

  title="$(bash -c "eval echo \"$title_tmpl\"")"
  match_title="$(bash -c "eval echo \"$match_title_tmpl\"")"
  body="$(bash -c "eval echo \"$body_tmpl\"")"
}

create_pr() {
  pr-creator \
    --github-token-path="$token_path" \
    --org="$org" \
    --repo="$repo" \
    --branch="$branch" \
    --title="$title" \
    --match-title="\"$match_title\"" \
    --body="$body" \
    --source="$user:$branch-$modifier" \
    --confirm
}

work() {
  evaluate_opts

  git clone --single-branch --branch "$branch" "https://github.com/$org/$repo.git" "$repo"

  pushd "$repo" || print_error_and_exit "invalid repo: $repo"

  bash "$script_path"

  if ! git diff --quiet --exit-code; then
    git add --all
    git -c "user.name=$user" -c "user.email=$email" commit --message "$title" --author="$user <$email>"
    git show --shortstat
    git push --force "https://$user:$token@github.com/$user/$repo.git" "HEAD:$branch-$modifier"

    create_pr
  fi

  popd || print_error_and_exit "invalid repo: $repo"
}

main() {
  trap cleanup EXIT

  tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)

  get_opts "$@"
  validate_opts

  pushd "$tmp_dir" || print_error_and_exit "invalid dir: $tmp_dir"

  for repo in "${repos[@]}"; do
    work || continue
  done

  popd || print_error_and_exit "invalid dir: $tmp_dir"
}

main "$@"
