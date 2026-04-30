#!/bin/sh

set -eu

OWNER="phillipmcmahon"
REPO="pwned-check"
PROJECT_NUMBER="2"
ISSUE=""
STAGE=""
CLOSE_ISSUE=0
REOPEN_ISSUE=0

usage() {
    cat <<'EOF'
Usage: ./scripts/project-transition.sh --issue <number> --stage <stage> [OPTIONS]

Move one issue through the project board workflow and keep status labels aligned.

Stages:
  ready          Status=Todo, Workflow=Ready, remove status labels
  in-progress    Status=In Progress, Workflow=In Progress, status:in-progress
  review         Status=In Progress, Workflow=Review, status:review
  done           Status=Done, Workflow=Done, remove status labels

Options:
  --owner <login>        GitHub owner (default: phillipmcmahon)
  --repo <name>          GitHub repo name (default: pwned-check)
  --project <number>    GitHub project number (default: 2)
  --issue <number>      Issue number to transition
  --stage <stage>       ready, in-progress, review, or done
  --close               Close the issue after setting stage=done
  --reopen              Reopen the issue before applying a non-done stage
  --help                Show this help text
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --owner)
            [ "$#" -ge 2 ] || fail "--owner requires a value"
            OWNER="$2"
            shift 2
            ;;
        --repo)
            [ "$#" -ge 2 ] || fail "--repo requires a value"
            REPO="$2"
            shift 2
            ;;
        --project)
            [ "$#" -ge 2 ] || fail "--project requires a value"
            PROJECT_NUMBER="$2"
            shift 2
            ;;
        --issue)
            [ "$#" -ge 2 ] || fail "--issue requires a value"
            ISSUE="$2"
            shift 2
            ;;
        --stage)
            [ "$#" -ge 2 ] || fail "--stage requires a value"
            STAGE="$2"
            shift 2
            ;;
        --close)
            CLOSE_ISSUE=1
            shift
            ;;
        --reopen)
            REOPEN_ISSUE=1
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[ -n "$ISSUE" ] || fail "--issue is required"
[ -n "$STAGE" ] || fail "--stage is required"
[ "$CLOSE_ISSUE" -eq 0 ] || [ "$STAGE" = "done" ] || fail "--close can only be used with --stage done"

require_command gh
require_command jq

case "$STAGE" in
    ready)
        STATUS_NAME="Todo"
        WORKFLOW_NAME="Ready"
        ADD_LABEL=""
        ;;
    in-progress)
        STATUS_NAME="In Progress"
        WORKFLOW_NAME="In Progress"
        ADD_LABEL="status:in-progress"
        ;;
    review)
        STATUS_NAME="In Progress"
        WORKFLOW_NAME="Review"
        ADD_LABEL="status:review"
        ;;
    done)
        STATUS_NAME="Done"
        WORKFLOW_NAME="Done"
        ADD_LABEL=""
        ;;
    *)
        fail "--stage must be ready, in-progress, review, or done"
        ;;
esac

PROJECT_JSON="$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json)"
PROJECT_ID="$(printf '%s' "$PROJECT_JSON" | jq -r '.id')"
FIELDS_JSON="$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json)"
STATUS_FIELD_ID="$(printf '%s' "$FIELDS_JSON" | jq -r '.fields[] | select(.name == "Status") | .id')"
WORKFLOW_FIELD_ID="$(printf '%s' "$FIELDS_JSON" | jq -r '.fields[] | select(.name == "Workflow") | .id')"
STATUS_OPTION_ID="$(printf '%s' "$FIELDS_JSON" | jq -r --arg name "$STATUS_NAME" '.fields[] | select(.name == "Status") | .options[] | select(.name == $name) | .id')"
WORKFLOW_OPTION_ID="$(printf '%s' "$FIELDS_JSON" | jq -r --arg name "$WORKFLOW_NAME" '.fields[] | select(.name == "Workflow") | .options[] | select(.name == $name) | .id')"

[ -n "$STATUS_FIELD_ID" ] || fail "Status field not found"
[ -n "$WORKFLOW_FIELD_ID" ] || fail "Workflow field not found"
[ -n "$STATUS_OPTION_ID" ] || fail "Status option not found: $STATUS_NAME"
[ -n "$WORKFLOW_OPTION_ID" ] || fail "Workflow option not found: $WORKFLOW_NAME"

ISSUE_URL="https://github.com/$OWNER/$REPO/issues/$ISSUE"
ITEM_ID="$(gh api graphql \
    -f query='query($owner:String!, $repo:String!, $number:Int!, $project:ID!) { repository(owner:$owner, name:$repo) { issue(number:$number) { projectItems(first:20) { nodes { id project { id } } } } } }' \
    -f owner="$OWNER" \
    -f repo="$REPO" \
    -F number="$ISSUE" \
    -f project="$PROJECT_ID" \
    | jq -r --arg project "$PROJECT_ID" '.data.repository.issue.projectItems.nodes[] | select(.project.id == $project) | .id' \
    | head -n 1)"

if [ -z "$ITEM_ID" ]; then
    ITEM_ID="$(gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$ISSUE_URL" --format json --jq .id)"
fi

gh project item-edit --project-id "$PROJECT_ID" --id "$ITEM_ID" --field-id "$STATUS_FIELD_ID" --single-select-option-id "$STATUS_OPTION_ID" >/dev/null
gh project item-edit --project-id "$PROJECT_ID" --id "$ITEM_ID" --field-id "$WORKFLOW_FIELD_ID" --single-select-option-id "$WORKFLOW_OPTION_ID" >/dev/null

for label in status:in-progress status:review; do
    if gh issue view "$ISSUE" --repo "$OWNER/$REPO" --json labels --jq '.labels[].name' | grep -Fx "$label" >/dev/null 2>&1; then
        gh issue edit "$ISSUE" --repo "$OWNER/$REPO" --remove-label "$label" >/dev/null
    fi
done

if [ -n "$ADD_LABEL" ]; then
    gh issue edit "$ISSUE" --repo "$OWNER/$REPO" --add-label "$ADD_LABEL" >/dev/null
fi

if [ "$REOPEN_ISSUE" -eq 1 ]; then
    gh issue reopen "$ISSUE" --repo "$OWNER/$REPO" >/dev/null
fi

if [ "$CLOSE_ISSUE" -eq 1 ]; then
    gh issue close "$ISSUE" --repo "$OWNER/$REPO" >/dev/null
fi

echo "Issue #$ISSUE moved to $STAGE"
