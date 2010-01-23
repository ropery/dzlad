# Maintainer:  lolilolicon <lolilolicon#gmail#com>
# Contributor: lolilolicon <lolilolicon#gmail#com>

pkgname=dzlad
pkgver=0.1.1
pkgrel=1
pkgdesc="Dzlad helps you do some AUR tasks"
arch=(any)
url="http://github.com/lolilolicon/dzlad"
license=('MIT')
depends=(ruby)
source=(http://cloud.github.com/downloads/lolilolicon/dzlad/$pkgname-$pkgver.tar.gz)
md5sums=('93f68d3660a92b5c967e66c52d089b14')

build() {
  cd "$srcdir/$pkgname-$pkgver"

  install -d                     "$pkgdir/usr/lib/ruby/site_ruby/1.9.1/dzlad"
  install -m  644 lib/dzlad/*.rb "$pkgdir/usr/lib/ruby/site_ruby/1.9.1/dzlad"
  install -Dm 644 lib/dzlad.rb   "$pkgdir/usr/lib/ruby/site_ruby/1.9.1/"
  install -Dm 755 bin/dzlad      "$pkgdir/usr/bin/dzlad"

  install -Dm 644 LICENSE        "$pkgdir/usr/share/license/$pkgname/LICENSE"
}

# vim:set ts=2 sw=2 et:
