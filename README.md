# dpi-bypass

Türkiye'de erişimi engellenen Discord'u ve Roblox'u Windows'ta açmak için küçük bir paket. [zapret](https://github.com/bol-van/zapret) içindeki `winws` programını Windows hizmeti olarak kurar ve DNS'i şifreli Cloudflare DNS'e çevirir. VPN değildir. Trafik bilgisayarından doğrudan çıkar, sadece engelleyen cihazın (DPI) bağlantıyı tanıması zorlaştırılır. Bu işlem yalnızca `hostlist.txt` ve `hostlist-roblox.txt` içindeki alan adlarına ve Roblox oyun sunucularına uygulanır. Diğer oyunlar, yayınlar ve siteler etkilenmez.

### Roblox

Roblox'un kendi alan adı (`roblox.com`) DNS değiştirilince açılıyor. Asıl engel `rbxcdn.com`'da (Akamai). Oyun dosyaları (`c0`-`c7`), görseller (`t0`-`t7`, `tr`), sitenin JS/CSS dosyaları ve güncelleyici buradan gelir. Bu yüzden yalnızca DNS ile uygulamaya giriş yapılabiliyor, ama oyuna girilemiyor ve web sitesi yüklenmiyor. Paket `rbxcdn.com`'u da kapsar ve Roblox için Discord'dan **ayrı** bir yöntem seçer. Ayrıca oyun sunucularına giden UDP trafiğinin (49152-65535 portları, yalnızca Roblox'un IP blokları) ilk paketlerinden önce sahte paket gönderir. Bu sonuncusu `config.json` dosyasındaki `"RobloxGameUdp": false` ayarıyla kapatılabilir.

## Gereksinimler

- Windows 10 (1803 veya üstü) ya da Windows 11, 64 bit
- Yönetici yetkisi

## Kurulum

1. [Releases](../../releases) sayfasından zip'i indirip bir klasöre çıkarın.
2. `install.cmd` dosyasına çift tıklayın ve yönetici iznini onaylayın.
3. Defender istisnası sorulursa **E** deyin. Aksi halde Windows Defender, WinDivert'i "HackTool" diye silebilir ve program çalışmaz.
4. Kurulum bu ağda çalışan yöntemleri kendisi dener. Bu 1-4 dakika sürebilir. Discord ve Roblox için yeşil yazı çıkarsa hazırdır.
5. Discord açıksa sistem tepsisinden tamamen kapatıp yeniden açın. Roblox açıksa kapatıp yeniden açın, tarayıcıdaki Roblox sekmesini yenileyin.

Kurulumdan sonra zip'i çıkardığınız klasörü silebilirsiniz. Program `C:\Program Files\dpi-bypass` altından çalışır ve bilgisayar açılınca kendiliğinden başlar.

## Güncelleme

Eski sürüm kuruluysa **kaldırmanıza gerek yok**. Yeni zip'i ayrı bir klasöre çıkarıp `install.cmd` dosyasını çalıştırmanız yeterli. Kurulum bunu fark eder ve güncelleme yapar:

- `hostlist.txt` dosyasına sizin eklediğiniz alan adları korunur.
- İlk kurulumda alınan DNS yedeği korunur. Kaldırınca yine kurulumdan önceki ayarlar geri gelir.
- Yöntem bu ağ için yeniden seçilir. Daha önce Discord için seçilen yöntem ilk sırada denenir.

## Kurulum ne yapar?

| Adım | Ayrıntı |
|---|---|
| Yedek | DNS ayarları, DoH listesi ve varsa diğer DPI araçlarının durumu `C:\ProgramData\dpi-bypass\state\backup.json` dosyasına kaydedilir. Kaldırınca bunlar geri yüklenir. |
| Çakışan araçlar | GoodbyeDPI ya da başka bir winws çalışıyorsa durdurulur ve devre dışı bırakılır. İkisi aynı anda çalışırsa birbirini bozar. |
| DNS | Tüm fiziksel adaptörlerde DNS, Cloudflare'e (1.1.1.1 ve 2606:4700:4700::1111) çevrilir. Windows 11'de DNS yalnızca şifreli (DoH) gider. Windows 10'da DoH yoktur, DNS şifresiz gider. |
| Yöntem seçimi | Sırayla 11 winws yöntemi denenir. Discord ve Roblox için ayrı ayrı, tüm bağlantıları (TLS 1.2 ve 1.3) açan ilk yöntem seçilir. Roblox için site, oyuna giriş, oyun dosyaları, görseller ve güncelleyici test edilir. |
| Hizmet | `dpi-bypass-winws` hizmeti kurulur. Çökerse kendiliğinden yeniden başlar. |
| Sağlık kontrolü | `dpi-bypass-health` görevi dakikada bir çalışır. |

## Sağlık kontrolü

Her dakika internet, Discord ve Roblox bağlantısını kontrol eder:

- **Hizmet:** winws durmuşsa yeniden başlatır.
- **Yeni ağ kartı:** Yeni takılan bir ağ kartının (USB modem, telefon paylaşımı) DNS'ini ayarlar.
- **Genel sorun:** İnternet genel olarak gitmişse önce DNS önbelleğini temizler, sonra DNS ayarını yeniden uygular.
- **Sadece Discord / Roblox açılmıyor:** winws'i yeniden başlatır. Bu iki kez işe yaramazsa ağ değişmiş demektir ve yöntemi yeniden seçer (en fazla 30 dakikada bir).

Log dosyası: `C:\ProgramData\dpi-bypass\logs\health-YYYYMMDD.log`

## Çalışmıyorsa

1. `C:\Program Files\dpi-bypass\diagnose.cmd` dosyasını çalıştırın. Hiçbir ayarı değiştirmez. Sorunları raporun **SONUC** bölümünde listeler.
2. Ağ değiştiyse `select-strategy.cmd` ile yöntemi elle yeniden seçtirin.
3. Sık görülen sebepler:
   - **Antivirüs:** Defender ya da başka bir antivirüs WinDivert'i siliyor veya engelliyor. Kurulum klasörünü istisnaya ekleyin.
   - **Başka bir DNS ayarı:** Tarayıcının kendi "Güvenli DNS" ayarı, ya da açık bir VPN/proxy programı DNS'i başka yere yönlendiriyor olabilir.
   - **Giriş sayfalı Wi-Fi:** Otel, okul gibi ağlar giriş sayfası açılmadan şifreli DNS'e izin vermez. Giriş yapana kadar programı kaldırmanız gerekebilir.
   - **Roblox'ta oyuna girerken hata 279 / 277:** Önce `select-strategy.cmd` çalıştırın. Cloudflare WARP ya da başka bir VPN açıksa kapatın. Düzelmezse `C:\Program Files\dpi-bypass\config.json` içinde `RobloxGameUdp` ayarını değiştirin (`true`/`false`) ve `select-strategy.cmd`'yi yeniden çalıştırın.

## Başka bir siteyi eklemek

`C:\Program Files\dpi-bypass\hostlist.txt` dosyasını yönetici olarak açın ve her satıra bir alan adı yazın (Roblox'la ilgili alan adları `hostlist-roblox.txt` dosyasına yazılır). Alt alan adları da kapsanır. Sonra hizmeti yeniden başlatın:

```powershell
Restart-Service dpi-bypass-winws
```

## Kaldırma

`C:\Program Files\dpi-bypass\uninstall.cmd` dosyasına çift tıklayın. Hizmeti, görevleri ve Defender istisnasını siler. DNS ayarlarını ve devre dışı bırakılan araçları kurulumdan önceki hâline döndürür.

## Dosyalar

| Dosya | Görevi |
|---|---|
| `install.cmd` / `install.ps1` | Kurulum. Tekrar çalıştırılırsa günceller. |
| `uninstall.cmd` / `uninstall.ps1` | Kaldırma. |
| `diagnose.cmd` / `diagnose.ps1` | Teşhis raporu. |
| `select-strategy.cmd` / `select-strategy.ps1` | Yöntemi yeniden seçer. |
| `health-check.ps1` | Dakikalık sağlık kontrolü. |
| `lib.ps1` | Ortak kod: yöntem listesi, testler, DNS. |
| `config.json` | DNS sunucuları, kontrol adresleri, süreler, Roblox UDP ayarı. |
| `hostlist.txt` | DPI aşmanın uygulandığı alan adları (Discord ve kullanıcının ekledikleri). |
| `hostlist-roblox.txt` | Roblox alan adları. Roblox için seçilen yöntemle işlenir. Roblox oyun sunucularının IP blokları `lib.ps1` içindedir (`$RobloxGameNets`). |
| `bin\` | zapret `winws` ve WinDivert. Bkz. [THIRD-PARTY.md](THIRD-PARTY.md). |
| `tools\fetch-zapret.ps1` | zapret dosyalarını sabit bir commit'ten indirir ve hash'lerini doğrular. |

## Güvenlik notu

`winws.exe` imzasızdır. `WinDivert64.sys` imzalı bir çekirdek sürücüsüdür ve ağ paketlerini yakalayabilir. Bu yüzden antivirüsler bunları "HackTool" olarak işaretleyebilir. Dosyaların SHA256 değerleri `lib.ps1` içinde tutulur. Kurulum, kopyalamadan önce ve sonra bu değerleri kontrol eder.
