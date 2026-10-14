# RPM spec. Expects a built bundle in build/linux/x64/release/bundle
# (rpmbuild -bb --define "_srcdir $PWD" packaging/fboard.spec).
Name:           fboard
Version:        1.0.0
Release:        1%{?dist}
Summary:        Soundboard that plays sounds through your microphone
License:        GPL-3.0-or-later
URL:            https://github.com/proshiv85-byte/fboard
ExclusiveArch:  x86_64
Recommends:     pipewire-pulseaudio

%description
fboard is a free and open-source soundboard for Linux. It plays sounds into
your microphone so others hear them in voice chats and games, with global
hotkeys, categories, a hotbar, a recorder and a sound editor.

%install
%{_srcdir}/packaging/install.sh %{_srcdir}/build/linux/x64/release/bundle %{buildroot} /usr

%post
udevadm control --reload-rules >/dev/null 2>&1 || :
udevadm trigger --subsystem-match=misc --sysname-match=uinput >/dev/null 2>&1 || :

%files
/usr/bin/fboard
/usr/lib/fboard
/usr/share/applications/io.github.proshiv85_byte.fboard.desktop
/usr/share/metainfo/io.github.proshiv85_byte.fboard.metainfo.xml
/usr/share/icons/hicolor/scalable/apps/io.github.proshiv85_byte.fboard.svg
/usr/lib/udev/rules.d/70-fboard.rules
%license /usr/share/licenses/fboard/LICENSE
