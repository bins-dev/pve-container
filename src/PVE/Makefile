SOURCES=LXC.pm

.PHONY: install
install: $(SOURCES)
	install -d -m 0755 $(PERLDIR)/PVE
	for i in $(SOURCES); do install -D -m 0644 $$i $(PERLDIR)/PVE/$$i; done
	make -C API2 install
	make -C LXC install
	make -C VZDump install
	make -C CLI install


