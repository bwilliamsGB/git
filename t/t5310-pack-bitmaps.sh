#!/bin/sh

test_description='exercise basic bitmap functionality'
. ./test-lib.sh

objpath () {
	echo ".git/objects/$(echo "$1" | sed -e 's|\(..\)|\1/|')"
}

# show objects present in pack ($1 should be associated *.idx)
packobjects () {
	git show-index <$1 | cut -d' ' -f2
}

# hasany pattern-file content-file
# tests whether content-file has any entry from pattern-file with entries being
# whole lines.
hasany () {
	# NOTE `grep -f` is not portable
	git grep --no-index -qFf $1 $2
}

test_expect_success 'setup repo with moderate-sized history' '
	for i in $(test_seq 1 10); do
		test_commit $i
	done &&
	git checkout -b other HEAD~5 &&
	for i in $(test_seq 1 10); do
		test_commit side-$i
	done &&
	git checkout master &&
	bitmaptip=$(git rev-parse master) &&
	blob=$(echo tagged-blob | git hash-object -w --stdin) &&
	git tag tagged-blob $blob &&
	git config repack.writebitmaps true &&
	git config pack.writebitmaphashcache true
'

test_expect_success 'full repack creates bitmaps' '
	git repack -ad &&
	ls .git/objects/pack/ | grep bitmap >output &&
	test_line_count = 1 output
'

test_expect_success 'rev-list --test-bitmap verifies bitmaps' '
	git rev-list --test-bitmap HEAD
'

rev_list_tests() {
	state=$1

	test_expect_success "counting commits via bitmap ($state)" '
		git rev-list --count HEAD >expect &&
		git rev-list --use-bitmap-index --count HEAD >actual &&
		test_cmp expect actual
	'

	test_expect_success "counting partial commits via bitmap ($state)" '
		git rev-list --count HEAD~5..HEAD >expect &&
		git rev-list --use-bitmap-index --count HEAD~5..HEAD >actual &&
		test_cmp expect actual
	'

	test_expect_success "counting commits with limit ($state)" '
		git rev-list --count -n 1 HEAD >expect &&
		git rev-list --use-bitmap-index --count -n 1 HEAD >actual &&
		test_cmp expect actual
	'

	test_expect_success "counting non-linear history ($state)" '
		git rev-list --count other...master >expect &&
		git rev-list --use-bitmap-index --count other...master >actual &&
		test_cmp expect actual
	'

	test_expect_success "counting commits with limiting ($state)" '
		git rev-list --count HEAD -- 1.t >expect &&
		git rev-list --use-bitmap-index --count HEAD -- 1.t >actual &&
		test_cmp expect actual
	'

	test_expect_success "enumerate --objects ($state)" '
		git rev-list --objects --use-bitmap-index HEAD >tmp &&
		cut -d" " -f1 <tmp >tmp2 &&
		sort <tmp2 >actual &&
		git rev-list --objects HEAD >tmp &&
		cut -d" " -f1 <tmp >tmp2 &&
		sort <tmp2 >expect &&
		test_cmp expect actual
	'

	test_expect_success "bitmap --objects handles non-commit objects ($state)" '
		git rev-list --objects --use-bitmap-index HEAD tagged-blob >actual &&
		grep $blob actual
	'
}

rev_list_tests 'full bitmap'

test_expect_success 'clone from bitmapped repository' '
	git clone --no-local --bare . clone.git &&
	git rev-parse HEAD >expect &&
	git --git-dir=clone.git rev-parse HEAD >actual &&
	test_cmp expect actual
'

test_expect_success 'setup further non-bitmapped commits' '
	for i in $(test_seq 1 10); do
		test_commit further-$i
	done
'

rev_list_tests 'partial bitmap'

test_expect_success 'fetch (partial bitmap)' '
	git --git-dir=clone.git fetch origin master:master &&
	git rev-parse HEAD >expect &&
	git --git-dir=clone.git rev-parse HEAD >actual &&
	test_cmp expect actual
'

test_expect_success 'incremental repack cannot create bitmaps' '
	test_commit more-1 &&
	find .git/objects/pack -name "*.bitmap" >expect &&
	git repack -d &&
	find .git/objects/pack -name "*.bitmap" >actual &&
	test_cmp expect actual
'

test_expect_success 'incremental repack can disable bitmaps' '
	test_commit more-2 &&
	git repack -d --no-write-bitmap-index
'

test_expect_success 'pack-objects respects --local (non-local loose)' '
	mkdir -p alt_objects/pack &&
	echo $(pwd)/alt_objects >.git/objects/info/alternates &&
	echo content1 >file1 &&
	# non-local loose object which is not present in bitmapped pack
	objsha1=$(GIT_OBJECT_DIRECTORY=alt_objects git hash-object -w file1) &&
	# non-local loose object which is also present in bitmapped pack
	git cat-file blob $blob | GIT_OBJECT_DIRECTORY=alt_objects git hash-object -w --stdin &&
	git add file1 &&
	test_tick &&
	git commit -m commit_file1 &&
	echo HEAD | git pack-objects --local --stdout --revs >1.pack &&
	git index-pack 1.pack &&
	packobjects 1.idx >1.objects &&
	printf "$objsha1\n$blob\n" >nonlocal-loose &&
	if hasany nonlocal-loose 1.objects; then
		echo "Non-local object present in pack generated with --local"
		return 1
	fi
'

test_expect_success 'pack-objects respects --honor-pack-keep (local non-bitmapped pack)' '
	echo content2 >file2 &&
	objsha2=$(git hash-object -w file2) &&
	git add file2 &&
	test_tick &&
	git commit -m commit_file2 &&
	printf "$objsha2\n$bitmaptip\n" >keepobjects &&
	pack2=$(git pack-objects pack2 <keepobjects) &&
	mv pack2-$pack2.* .git/objects/pack/ &&
	touch .git/objects/pack/pack2-$pack2.keep &&
	rm $(objpath $objsha2) &&
	echo HEAD | git pack-objects --honor-pack-keep --stdout --revs >2a.pack &&
	git index-pack 2a.pack &&
	packobjects 2a.idx >2a.objects &&
	if hasany keepobjects 2a.objects; then
		echo "Object from .keeped pack present in pack generated with --honor-pack-keep"
		return 1
	fi
'

test_expect_success 'pack-objects respects --local (non-local pack)' '
	mv .git/objects/pack/pack2-$pack2.* alt_objects/pack/ &&
	echo HEAD | git pack-objects --local --stdout --revs >2b.pack &&
	git index-pack 2b.pack &&
	packobjects 2b.idx >2b.objects &&
	if hasany keepobjects 2b.objects; then
		echo "Non-local object present in pack generated with --local"
		return 1
	fi
'

test_expect_success 'pack-objects respects --honor-pack-keep (local bitmapped pack)' '
	ls .git/objects/pack/ | grep bitmap >output &&
	test_line_count = 1 output &&
	packbitmap=$(basename $(cat output) .bitmap) &&
	packobjects .git/objects/pack/$packbitmap.idx >packbitmap.objects &&
	touch .git/objects/pack/$packbitmap.keep &&
	echo HEAD | git pack-objects --honor-pack-keep --stdout --revs >3a.pack &&
	git index-pack 3a.pack &&
	packobjects 3a.idx >3a.objects &&
	if hasany packbitmap.objects 3a.objects; then
		echo "Object from .keeped bitmapped pack present in pack generated with --honour-pack-keep"
		return 1
	fi &&
	rm .git/objects/pack/$packbitmap.keep
'

test_expect_success 'pack-objects respects --local (non-local bitmapped pack)' '
	mv .git/objects/pack/$packbitmap.* alt_objects/pack/ &&
	echo HEAD | git pack-objects --local --stdout --revs >3b.pack &&
	git index-pack 3b.pack &&
	packobjects 3b.idx >3b.objects &&
	if hasany packbitmap.objects 3b.objects; then
		echo "Non-local object from bitmapped pack present in pack generated with --local"
		return 1
	fi &&
	mv alt_objects/pack/$packbitmap.* .git/objects/pack/
'

test_expect_success 'full repack, reusing previous bitmaps' '
	git repack -ad &&
	ls .git/objects/pack/ | grep bitmap >output &&
	test_line_count = 1 output
'

test_expect_success 'fetch (full bitmap)' '
	git --git-dir=clone.git fetch origin master:master &&
	git rev-parse HEAD >expect &&
	git --git-dir=clone.git rev-parse HEAD >actual &&
	test_cmp expect actual
'

test_expect_success 'create objects for missing-HAVE tests' '
	blob=$(echo "missing have" | git hash-object -w --stdin) &&
	tree=$(printf "100644 blob $blob\tfile\n" | git mktree) &&
	parent=$(echo parent | git commit-tree $tree) &&
	commit=$(echo commit | git commit-tree $tree -p $parent) &&
	cat >revs <<-EOF
	HEAD
	^HEAD^
	^$commit
	EOF
'

test_expect_success 'pack-objects respects --incremental' '
	cat >revs2 <<-EOF &&
	HEAD
	$commit
	EOF
	git pack-objects --incremental --stdout --revs <revs2 >4.pack &&
	git index-pack 4.pack &&
	packobjects 4.idx >4.objects &&
	test_line_count = 4 4.objects &&
	git rev-list --objects $commit >revlist &&
	cut -d" " -f1 revlist |sort >objects &&
	if !hasany objects 4.objects; then
		echo "Expected objects not present in incremental pack"
		return 1
	fi
'

test_expect_success 'pack with missing blob' '
	rm $(objpath $blob) &&
	git pack-objects --stdout --revs <revs >/dev/null
'

test_expect_success 'pack with missing tree' '
	rm $(objpath $tree) &&
	git pack-objects --stdout --revs <revs >/dev/null
'

test_expect_success 'pack with missing parent' '
	rm $(objpath $parent) &&
	git pack-objects --stdout --revs <revs >/dev/null
'

test_lazy_prereq JGIT '
	type jgit
'

test_expect_success JGIT 'we can read jgit bitmaps' '
	git clone . compat-jgit &&
	(
		cd compat-jgit &&
		rm -f .git/objects/pack/*.bitmap &&
		jgit gc &&
		git rev-list --test-bitmap HEAD
	)
'

test_expect_success JGIT 'jgit can read our bitmaps' '
	git clone . compat-us &&
	(
		cd compat-us &&
		git repack -adb &&
		# jgit gc will barf if it does not like our bitmaps
		jgit gc
	)
'

test_expect_success 'splitting packs does not generate bogus bitmaps' '
	test-genrandom foo $((1024 * 1024)) >rand &&
	git add rand &&
	git commit -m "commit with big file" &&
	git -c pack.packSizeLimit=500k repack -adb &&
	git init --bare no-bitmaps.git &&
	git -C no-bitmaps.git fetch .. HEAD
'

test_done
