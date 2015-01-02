NAME=staticfarm-apache-handlers
all: version documentation build
build:
install: 
	test ! -d $(DESTDIR)/usr/share/staticfarm/apache/handlers/StaticFarm && mkdir -p $(DESTDIR)/usr/share/staticfarm/apache/handlers/StaticFarm || exit 0
	cp -R ./src/StaticFarm/* $(DESTDIR)/usr/share/staticfarm/apache/handlers/StaticFarm
deinstall:
	test -d $(DESTDIR)/usr/share/staticfarm/apache/handlers && rm -r $(DESTDIR)/usr/share/staticfarm/apache/handlers || exit 0
clean:
# Parses the version out of the Debian changelog
version:
	cut -d' ' -f2 debian/changelog | head -n 1 | sed 's/(//;s/)//' > .version
# Builds the documentation into a manpage
documentation:
	pod2man --release="$(NAME) $$(cat .version)" \
		--center="User Commands" ./docs/$(NAME).pod > ./docs/$(NAME).1
	pod2text ./docs/$(NAME).pod > ./docs/$(NAME).txt
	cp ./docs/$(NAME).pod ./README.pod
# Build a debian package (don't sign it, modify the arguments if you want to sign it)
deb:
	dpkg-buildpackage -uc -us
dch: 
	dch -i
release: dch version deb
	git commit -a -m 'New release'
	bash -c "git tag $$(cat .version)"
	git push --tags
	git push origin master
clean-top:
	rm ../$(NAME)_*.tar.gz
	rm ../$(NAME)_*.dsc
	rm ../$(NAME)_*.changes
	rm ../$(NAME)_*.deb
