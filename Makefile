OCAMLMAKEFILE = OCamlMakefile
 
SOURCES = printer_utils.ml mpl_utils.ml mpl_types.ml mpl_location.ml mpl_bits.ml \
	mpl_syntaxtree.ml mpl_typechk.ml mpl_parser.mli \
	mpl_lexer.ml mpl_parser.ml mpl_cfg.ml mpl_ocaml.ml mplc.ml
RESULT = mplc
TRASH = mpl_parser.output mpl_parser.ml mpl_lexer.ml mpl_parser.mli
LIBS = unix

PREFIX ?= /usr/local

.PHONY: install all

all: nc
install: nc
	mkdir -p $(DESTDIR)$(PREFIX)/bin
	install -m 755 mplc $(DESTDIR)$(PREFIX)/bin/mplc

.PHONY: rpm
rpm:
	make clean && make -f Makefile.stdlib clean
	tar -C .. -cvjf /usr/src/redhat/SOURCES/mpl.tar.bz2 mpl
	cp -f mpl.spec /usr/src/redhat/SPECS
	rpmbuild -ba /usr/src/redhat/SPECS/mpl.spec

include $(OCAMLMAKEFILE)
