# -*- rpm-spec -*-

Summary: mpl - Tools for efficient packet marshalling/unmarshalling
Name:    mpl
Version: 0
Release: 1
Group:   Development/Tools/OCaml
License: BSD
URL:  http://githib.com/avsm/mpl
Source0: mpl.tar.bz2
BuildRoot: %{_tmppath}/%{name}-%{version}-root

%description
MPL is a compiler which accepts succinct binary packet descriptions
and outputs fast, type-safe OCaml interfaces and modules to marshal
and unmarshal packets of this type.

It is primarily aimed at binary low-level protocols such as IP, TCP or
Ethernet, and C structure marshalling.

%prep 
%setup -q -n mpl
%build
%{__make} 
%{__make} -f Makefile.stdlib

%install
rm -rf %{buildroot}

DESTDIR=$RPM_BUILD_ROOT %{__make} install 
DESTDIR=$RPM_BUILD_ROOT %{__make} -f Makefile.stdlib install 

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
/usr/local/bin/mplc
/usr/lib/ocaml/mpl/mpl_stdlib.cmx
/usr/lib/ocaml/mpl/mpl_stdlib.cmo
/usr/lib/ocaml/mpl/mpl_stdlib.cmi
/usr/lib/ocaml/mpl/META
