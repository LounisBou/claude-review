"""Pull request reads."""

import subprocess

from . import http, repo


def _current_branch():
    return subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True, check=False
    ).stdout.strip()


def auth_check(args):
    return http.rest("GET", "/user")


def pr_get(args):
    owner, name = repo.owner_repo()
    branch = args.branch or _current_branch()
    return http.rest("GET", "/repos/%s/%s/pulls?head=%s:%s" % (owner, name, owner, branch))


def pr_list(args):
    owner, name = repo.owner_repo()
    return http.rest("GET", "/repos/%s/%s/pulls?state=open" % (owner, name), paginate=True)


def pr_status(args):
    owner, name = repo.owner_repo()
    return http.rest("GET", "/repos/%s/%s/pulls/%s" % (owner, name, args.pr))


def pr_checks(args):
    owner, name = repo.owner_repo()
    pull = http.rest("GET", "/repos/%s/%s/pulls/%s" % (owner, name, args.pr))
    sha = (pull.get("head") or {}).get("sha", "")
    statuses = http.rest("GET", "/repos/%s/%s/commits/%s/status" % (owner, name, sha))
    runs = http.rest("GET", "/repos/%s/%s/commits/%s/check-runs" % (owner, name, sha))
    return {"statuses": statuses, "check_runs": runs.get("check_runs", [])}


def register(subparsers):
    parser = subparsers.add_parser("auth-check", help="verify the token works")
    parser.set_defaults(handler=auth_check)

    parser = subparsers.add_parser("pr-get", help="get the PR for a branch")
    parser.add_argument("--branch", default=None, help="defaults to the current branch")
    parser.set_defaults(handler=pr_get)

    parser = subparsers.add_parser("pr-list", help="list open PRs")
    parser.set_defaults(handler=pr_list)

    parser = subparsers.add_parser("pr-status", help="get PR state")
    parser.add_argument("pr")
    parser.set_defaults(handler=pr_status)

    parser = subparsers.add_parser("pr-checks", help="combined status and check runs")
    parser.add_argument("pr")
    parser.set_defaults(handler=pr_checks)
