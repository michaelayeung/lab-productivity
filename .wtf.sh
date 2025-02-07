# This script enables a new bash command `wtf` that helps debug the most recent errors in a terminal session.
# It should be sourced from .bashrc or a terminal session.

[[ $0 == "$BASH_SOURCE" ]] && echo "This script should be sourced, not executed." && exit

# We use a trick to take over the current shell session.
# The first time this file is sources,
# $WTF_FILE will not be defined and the body of the if will execute.
# The body of the if statement puts us in a `script` environment,
# which records our shell session.
# It also stops execution of this file, however.
# So within the script we source this file a second time,
# the if condition will be false,
# and the rest of this file will run.
# We must immediately source the ~/.bashrc file because 
if [ -z "$WTF_FILE" ]; then
    # The contents of $WTF_FILE will contain the full history of the current shell session.
    # Shell histories can contain sensitive information like API keys,
    # and so we create the file with restrictive permissions.
    export WTF_FILE=$(mktemp)
    chmod 600 "$WTF_FILE"
    exec script --quiet -c 'bash --init-file .wtf.sh' -f "$WTF_FILE"
fi
source ~/.bashrc

# `trap` runs the command in $1 whenever event $2 occurs.
# Here, we use it to delete the file whenever our shell session ends.
# Because this file is being sourced, and not executed,
# the session ending corresponds to logging out of the terminal.
trap "rm -f $WTF_FILE" EXIT

# The main body of this script defines two functions:
# `_wtf` generates a prompt that asks an LLM for debugging help.
# It includes lots of potentially useful related information,
# but also has checks to try to keep the prompt small
# so that it stays under ~8k tokens to be compatible with the groq API.
# These checks are only heuristic.
_wtf() {
    CONTEXT_LINES=100
    # The tail commands truncate the session history.
    # The first command truncates by the number of lines,
    # and the second truncates by the number of characters
    # (so that a single long line doesn't explode the history size).
    # The tr command removes and null characters
    # (they are not visible but mess up the llm).
    # I previously also added the following sed command:
    # `sed 's/\x1b\[[0-9;]*m//g'`
    # to remove ANSI characters for better human display,
    # but this also removes characters that the LLM may need.
    SESSION_HISTORY=$(
        tail -n "$CONTEXT_LINES" "$WTF_FILE"    \
        | tail -c $(($CONTEXT_LINES * 80))      \
        | tr -d '\0'
        )

    # This incantation adds python/shell source files into the context with appropriate labels.
    # It is a hacky version of <https://github.com/simonw/files-to-prompt>,
    # but better for our use here since it truncates the files to reduce context-window size.
    CODE_FILES=$(
        find . -maxdepth 1 -type f \( -name "*.py" -o -name "*.sh" \) -not -name ".*" -print -exec cat {} \; -exec echo --- \; | head -n 1000 | head -c 8000
        )

    # The prompt below concatenates our history, some information about the current environment, and the code files.
    PROMPT=$(cat <<EOF
Below is the last $CONTEXT_LINES lines of a shell session.
Something bad happened that I'm trying to debug.
Explain the problem and how to fix it at a beginner level working through any possible edge cases.
If possible be concise (<10 lines), but maintain good markdown formatting and prefer markdown code blocks to inline code.
Only provide help with the most recent error and ignore previous errors.
\`\`\`
$SESSION_HISTORY
\`\`\`
In case it is helpful, here is some info about the system.
Do not mention this info unless it is related to the problem.
\`\`\`
\$ uname -a
$(uname -a)
\$ pwd
$(pwd)
\$ ls
$(ls)
\`\`\`
The contents of possibly relavent files include
\`\`\`
$CODE_FILES
\`\`\`
EOF
)
    echo "$PROMPT"
}

# wtf passes the prompt generated by _wtf to the groq LLM
wtf() {
    _wtf | groq
}
