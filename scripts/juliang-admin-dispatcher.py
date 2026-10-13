from pathlib import Path
import sys
source=Path(sys.argv[1]);target=Path(sys.argv[2]);policy=Path(sys.argv[3]).read_text()
s=source.read_text();anchor="\tif (cachefile) {\n\t\tlet fd = open(cachefile, 'w', 0600);"
assert anchor in s and 'function juliang_scope_tree' not in s
s=s.replace('function build_pagetree() {',policy+'\nfunction build_pagetree() {',1)
s=s.replace(anchor,'\tjuliang_scope_tree(tree, []);\n\n'+anchor,1)
target.parent.mkdir(parents=True,exist_ok=True);target.write_text(s)
