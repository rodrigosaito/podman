#!/usr/bin/env bats

load helpers

@test "podman images - basic output" {
    run_podman images -a

    is "${lines[0]}" "REPOSITORY *TAG *IMAGE ID *CREATED *SIZE" "header line"
    is "${lines[1]}" "$PODMAN_TEST_IMAGE_REGISTRY/$PODMAN_TEST_IMAGE_USER/$PODMAN_TEST_IMAGE_NAME *$PODMAN_TEST_IMAGE_TAG *[0-9a-f]\+" "podman images output"
}

@test "podman images - custom formats" {
    tests="
--format {{.ID}}                  |        [0-9a-f]\\\{12\\\}
--format {{.ID}} --no-trunc       | sha256:[0-9a-f]\\\{64\\\}
--format {{.Repository}}:{{.Tag}} | $PODMAN_TEST_IMAGE_FQN
"

    parse_table "$tests" | while read fmt expect; do
        run_podman images $fmt
        is "$output" "$expect\$" "podman images $fmt"
    done

}


@test "podman images - json" {
    # 'created': podman includes fractional seconds, podman-remote does not
    tests="
Names[0]    | $PODMAN_TEST_IMAGE_FQN
Id          |        [0-9a-f]\\\{64\\\}
Digest      | sha256:[0-9a-f]\\\{64\\\}
CreatedAt   | [0-9-]\\\+T[0-9:.]\\\+Z
Size        | [0-9]\\\+
"

    run_podman images -a --format json

    parse_table "$tests" | while read field expect; do
        actual=$(echo "$output" | jq -r ".[0].$field")
        dprint "# actual=<$actual> expect=<$expect}>"
        is "$actual" "$expect" "jq .$field"
    done

}

@test "podman images - history output" {
    # podman history is persistent: it permanently alters our base image.
    # Create a dummy image here so we leave our setup as we found it.
    run_podman run --name my-container $IMAGE true
    run_podman commit my-container my-test-image

    run_podman images my-test-image --format '{{ .History }}'
    is "$output" "" "Image has empty history to begin with"

    # Generate two randomish tags; 'tr' because they must be all lower-case
    rand_name1="test-image-history-$(random_string 10 | tr A-Z a-z)"
    rand_name2="test-image-history-$(random_string 10 | tr A-Z a-z)"

    # Tag once, rmi, and make sure the tag name appears in history
    run_podman tag my-test-image $rand_name1
    run_podman rmi $rand_name1
    run_podman images my-test-image --format '{{ .History }}'
    is "$output" "localhost/${rand_name1}:latest" "image history after one tag"

    # Repeat with second tag. Now both tags should be in history
    run_podman tag my-test-image $rand_name2
    run_podman rmi $rand_name2
    run_podman images my-test-image --format '{{ .History }}'
    is "$output" "localhost/${rand_name2}:latest, localhost/${rand_name1}:latest" \
       "image history after two tags"

    run_podman rmi my-test-image
    run_podman rm my-container
}

@test "podman images - filter" {
    skip_if_remote "podman commit -q is broken in podman-remote"

    run_podman inspect --format '{{.ID}}' $IMAGE
    iid=$output

    run_podman images --noheading --filter=after=$iid
    is "$output" "" "baseline: empty results from filter (after)"

    run_podman images --noheading --filter=before=$iid
    is "$output" "" "baseline: empty results from filter (before)"

    # Create a dummy container, then commit that as an image. We will
    # now be able to use before/after/since queries
    run_podman run --name mytinycontainer $IMAGE true
    run_podman commit -q  mytinycontainer mynewimage
    new_iid=$output

    # (refactor common options for legibility)
    opts='--noheading --no-trunc --format={{.ID}}--{{.Repository}}:{{.Tag}}'

    run_podman images ${opts} --filter=after=$iid
    is "$output" "sha256:$new_iid--localhost/mynewimage:latest" "filter: after"

    # Same thing, with 'since' instead of 'after'
    run_podman images ${opts} --filter=since=$iid
    is "$output" "sha256:$new_iid--localhost/mynewimage:latest" "filter: since"

    run_podman images ${opts} --filter=before=mynewimage
    is "$output" "sha256:$iid--$IMAGE" "filter: before"

    # Clean up
    run_podman rmi mynewimage
    run_podman rm  mytinycontainer
}

# Regression test for https://github.com/containers/podman/issues/7651
# in which "podman pull image-with-sha" causes "images -a" to crash
@test "podman images -a, after pulling by sha " {
    # Get the digest of our local test image. We need to do this in two steps
    # because 'podman inspect' only works reliably on *IMAGE ID*, not name.
    # See https://github.com/containers/podman/issues/3761
    run_podman inspect --format '{{.Id}}' $IMAGE
    local iid="$output"
    run_podman inspect --format '{{.Digest}}' $iid
    local sha="$output"

    local imgbase="${PODMAN_TEST_IMAGE_REGISTRY}/${PODMAN_TEST_IMAGE_USER}/${PODMAN_TEST_IMAGE_NAME}"
    local fqin="${imgbase}@$sha"

    # This will always pull, because even though it's the same image we
    # already have, podman doesn't actually know that.
    run_podman pull $fqin
    is "$output" "Trying to pull ${fqin}\.\.\..*" "output of podman pull"

    # Prior to #7654, this would crash and burn. Now it at least succeeds,
    # although on the 2.0.5-rhel branch it lists two images: our original,
    # and one with the same name but with a tag of '<none>'. (This differs
    # from podman @ master branch, in which podman recognizes it as the
    # same image and shows only one line).
    #
    # WARNING! If this test fails, we're going to see a lot of failures
    # in subsequent tests due to 'podman ps' showing the '@sha' tag!
    # I choose not to add a complicated teardown() (with 'rmi @sha')
    # because the failure window here is small, and if it fails it
    # needs attention anyway. So if you see lots of failures, but
    # start here because this is the first one, fix this problem.
    # You can (probably) ignore any subsequent failures showing '@sha'
    # in the error output.
    run_podman images -a --noheading --sort=tag
    is "${lines[0]}" "${imgbase}  <none> \+${iid:0:12} .*" \
       "images -a: first line: shows image with no tag"
    is "${lines[1]}" "${imgbase}  ${PODMAN_TEST_IMAGE_TAG} \+${iid:0:12} " \
       "images -a: second line: shows original image"

    # Clean up: this should simply untag, not remove
    run_podman rmi $fqin
    is "$output" "Untagged: $fqin" "podman rmi untags, does not remove"

    # ...and now we should still have our same image.
    run_podman images -a

    # ...and now we should be back to having exactly one image
    run_podman images -a --format '{{.Names}}'
    is "$output" "\[$IMAGE\]" "Back to our state with just the test image"
}

# vim: filetype=sh
