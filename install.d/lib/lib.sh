if ! command -v fzf &>2; then
  echo "install 'fzf' to use this tool"
fi

select-container() {
  local container=$(for d in "$REPO_ROOT/docker/"*; do 
    echo "$d"
  done | fzf)

  echo $container
}

