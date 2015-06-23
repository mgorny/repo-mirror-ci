#!/usr/bin/env python

import json
import os
import os.path
import sys

import github


GITHUB_USERNAME = 'gentoo-repo-qa-bot'
GITHUB_TOKEN_FILE = os.path.expanduser('~/.github-token')
GITHUB_ORG = 'gentoo-mirror'


def main(summary_path):
    with open(summary_path) as f:
        repos = json.load(f)

    with open(GITHUB_TOKEN_FILE) as f:
        token = f.read().strip()

    g = github.Github(GITHUB_USERNAME, token, per_page=50)
    gu = g.get_organization(GITHUB_ORG)
    gh_repos = set()

    # check repo states
    for data in repos.values():
        # 1. we don't add repos with broken metadata but we also don't
        # remove existing ones -- we hope maintainers will fix them,
        # or overlays team will remove them
        #
        # 2. remove repos with unsupported VCS -- this means that
        # upstream has switched, and there's no point in keeping
        # an outdated mirror
        #
        # 3. we can't update repos which are broken to the point of
        # being implicitly removed

        data['x-can-create'] = data['x-state'] in ('GOOD', 'BAD_CACHE')
        data['x-can-update'] = data['x-can-create']
        data['x-should-remove'] = data['x-state'] in ('REMOVED', 'UNSUPPORTED')

    # 0. scan all repos
    to_remove = []
    to_update = []
    for i, r in enumerate(gu.get_repos()):
        sys.stderr.write('\r@ scanning [%-3d/%-3d]' % (i+1, gu.public_repos))
        if r.name not in repos or repos[r.name]['x-should-remove']:
            to_remove.append(r)
        else:
            gh_repos.add(r.name)
            if repos[r.name]['x-can-update']:
                to_update.append(r)
    sys.stderr.write('\n')

    # 1. delete stale repos
    for r in to_remove:
        sys.stderr.write('* removing %s\n' % r.name)
        r.delete()

    # 2. now create new repos :)
    for r, data in sorted(repos.items()):
        if r not in gh_repos and data['x-can-create']:
            sys.stderr.write('* adding %s\n' % r)
            # description[1+] can be other languages
            # sadly, layman gives us no clue what language it is...
            gr = gu.create_repo(r,
                    description = data['description'][0] or github.GithubObject.NotSet,
                    homepage = data['homepage'] or github.GithubObject.NotSet,
                    has_issues = False,
                    has_wiki = False)
            to_update.append(gr)

    print('DELETED_REPOS = %s' % ' '.join(r.name for r in to_remove))
    print('REPOS = %s' % ' '.join(r.name for r in to_update))


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))