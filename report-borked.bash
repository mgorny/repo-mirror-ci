#!/bin/bash

set -e -x

repo=${GENTOO_CI_GIT}
borked_list=${repo}/borked.list
borked_last=${repo}/borked.last
uri_prefix=${GENTOO_CI_URI_PREFIX}
mail_to=${GENTOO_CI_MAIL}
mail_cc=()
previous_commit=${1}
next_commit=${2}

if [[ ! -s ${borked_list} ]]; then
	if [[ -s ${borked_last} ]]; then
		subject="FIXED: all failures have been fixed"
		mail="Everything seems nice and cool now."
	else
		exit 0
	fi
else
	if [[ ! -s ${borked_last} ]]; then
		subject="BROKEN: repository became broken!"
		mail="Looks like someone just broke Gentoo!"
	elif ! cmp -s "${borked_list}" "${borked_last}"; then
		subject="BROKEN: repository is still broken!"
		mail="Looks like the breakage list has just changed!"
	else
		exit 0
	fi
fi

current_rev=$(cd "${repo}"; git rev-parse --short HEAD)

fixed=()
old=()
new=()

while read t l; do
	case "${t}" in
		fixed) fixed+=( "${l}" );;
		old) old+=( "${l}" );;
		new) new+=( "${l}" );;
		*)
			echo "Invalid diff result: ${t} ${l}" >&2
			exit 1;;
	esac
done < <(diff -N \
		--old-line-format='fixed %L' \
		--unchanged-line-format='old %L' \
		--new-line-format='new %L' \
		"${borked_last}" "${borked_list}")

broken_commits=()
cc_line=()

if [[ ${new[@]} && ${previous_commit} && ${#new[@]} -lt 30 ]]; then
	trap 'rm -rf "${BISECT_TMP}"' EXIT
	export BISECT_TMP=$(mktemp -d)
	sed -e "s^@path@^${SYNC_DIR}/gentoo^" \
		"${TRAVIS_REPO_CHECKS_GIT}"/pkgcore.conf.in \
		> "${BISECT_TMP}"/.pkgcore.conf

	# check one commit extra to make sure the breakages were introduced
	# in the commit set; this could happen e.g. when new checks
	# are added on top of already-broken repo
	pre_previous_commit=$(cd "${SYNC_DIR}"/gentoo; git rev-parse "${previous_commit}^")
	set -- "${new[@]##*#}"
	while [[ ${@} ]]; do
		commit=$("${SCRIPT_DIR}"/bisect-borked.bash \
			"${next_commit}" "${pre_previous_commit}" "${@}")
		shift

		# skip breakages introduced before the commit set
		[[ ${pre_previous_commit} != ${commit}* ]] || continue

		# skip duplicates
		for c in "${broken_commits[@]}"; do
			[[ ${c} != ${commit} ]] || continue 2
		done
		broken_commits+=( "${commit}" )

		for a in $(cd "${SYNC_DIR}"/gentoo; git log --pretty='%ae %ce' "${commit}" -1)
		do
			for o in "${mail_cc[@]}"; do
				[[ ${o} != ${a} ]] || continue 2
			done
			mail_cc+=( "${a}" )
			cc_line+=( "<${a}>" )
		done
	done

	trap '' EXIT
	rm -rf "${BISECT_TMP}"
fi

cc_line=${cc_line[*]}

IFS='
'

mail="Subject: ${subject}
To: <${mail_to}>
${mail_cc[@]:+CC: ${cc_line// /, }
}Content-Type: text/plain; charset=utf8

${mail}

${new:+New issues:
${new[*]/#/
${uri_prefix}/${current_rev}/}


}${broken_commits:+Introduced by commits:
${broken_commits[*]/#/
${GENTOO_CI_GITWEB_COMMIT_URI}}


}${old:+Previous issues still unfixed:
${old[*]/#/
${uri_prefix}/${current_rev}/}


}${fixed:+Packages fixed since last run:
${fixed[*]/#/
${uri_prefix}/${current_rev}/}


}Changes since last check:
${GENTOO_CI_GITWEB_URI}${previous_commit}..${next_commit}

--
Gentoo repository CI"

sendmail "${mail_to}" "${mail_cc[@]}" <<<"${mail}"
cp "${borked_list}" "${borked_last}"
