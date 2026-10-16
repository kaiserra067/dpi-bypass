# dpi-bypass

Türkiye'de erişimi engellenen Discord'u Windows'ta açmak için küçük bir paket. [zapret](https://github.com/bol-van/zapret) içindeki `winws` programını Windows hizmeti olarak kurar ve DNS'i şifreli Cloudflare DNS'e çevirir. VPN değildir. Trafik bilgisayarından doğrudan çıkar, sadece engelleyen cihazın (DPI) bağlantıyı tanıması zorlaştırılır. Bu işlem yalnızca `hostlist.txt` içindeki alan adlarına uygulanır. Oyun, yayın ve diğer siteler etkilenmez.

## Gereksinimler

- Windows 10 (1803 veya üstü) ya da Windows 11, 64 bit
- Yönetici yetkisi

## Kurulum

1. [Releases](../../releases) sayfasından zip'i indirip bir klasöre çıkarın.
2. `install.cmd` dosyasına çift tıklayın ve yönetici iznini onaylayın.
3. Defender istisnası sorulursa **E** deyin. Aksi halde Windows Defender, WinDivert'i "HackTool" diye silebilir ve program çalışmaz.
4. Kurulum bu ağda çalışan yöntemi kendisi dener. Bu 1-3 dakika sürebilir. Sonunda yeşil yazı çıkarsa hazırdır.
5. Discord açıksa sistem tepsisinden tamamen kapatıp yeniden açın.

Kurulumdan sonra zip'i çıkardığınız klasörü silebilirsiniz. Program `C:\Program Files\dpi-bypass` altından çalışır ve bilgisayar açılınca kendiliğinden başlar.

## Kurulum ne yapar?

| Adım | Ayrıntı |
|---|---|
| Yedek | DNS ayarları, DoH listesi ve varsa diğer DPI araçlarının durumu `C:\ProgramData\dpi-bypass\state\backup.json` dosyasına kaydedilir. Kaldırınca bunlar geri yüklenir. |
| Çakışan araçlar | GoodbyeDPI ya da başka bir winws çalışıyorsa durdurulur ve devre dışı bırakılır. İkisi aynı anda çalışırsa birbirini bozar. |
| DNS | Tüm fiziksel adaptörlerde DNS, Cloudflare'e (1.1.1.1 ve 2606:4700:4700::1111) çevrilir. Windows 11'de DNS yalnızca şifreli (DoH) gider. Windows 10'da DoH yoktur, DNS şifresiz gider. |
| Yöntem seçimi | Sırayla 11 winws yöntemi denenir. Discord'un tüm bağlantılarını (TLS 1.2 ve 1.3) açan ilk yöntem seçilir. |
| Hizmet | `dpi-bypass-winws` hizmeti kurulur. Çökerse kendiliğinden yeniden başlar. |
| Sağlık kontrolü | `dpi-bypass-health` görevi dakikada bir çalışır. |

## Sağlık kontrolü

Her dakika internet ve Discord bağlantısını kontrol eder:

- **Hizmet:** winws durmuşsa yeniden başlatır.
- **Yeni ağ kartı:** Yeni takılan bir ağ kartının (USB modem, telefon paylaşımı) DNS'ini ayarlar.
- **Genel sorun:** İnternet genel olarak gitmişse önce DNS önbelleğini temizler, sonra DNS ayarını yeniden uygular.
- **Sadece Discord açılmıyor:** winws'i yeniden başlatır. Bu iki kez işe yaramazsa ağ değişmiş demektir ve yöntemi yeniden seçer (en fazla 30 dakikada bir).

Log dosyası: `C:\ProgramData\dpi-bypass\logs\health-YYYYMMDD.log`

## Çalışmıyorsa

1. `C:\Program Files\dpi-bypass\diagnose.cmd` dosyasını çalıştırın. Hiçbir ayarı değiştirmez. Sorunları raporun **SONUC** bölümünde listeler.
2. Ağ değiştiyse `select-strategy.cmd` ile yöntemi elle yeniden seçtirin.
3. Sık görülen sebepler:
   - **Antivirüs:** Defender ya da başka bir antivirüs WinDivert'i siliyor veya engelliyor. Kurulum klasörünü istisnaya ekleyin.
   - **Başka bir DNS ayarı:** Tarayıcının kendi "Güvenli DNS" ayarı, ya da açık bir VPN/proxy programı DNS'i başka yere yönlendiriyor olabilir.
   - **Giriş sayfalı Wi-Fi:** Otel, okul gibi ağlar giriş sayfası açılmadan şifreli DNS'e izin vermez. Giriş yapana kadar programı kaldırmanız gerekebilir.

## Başka bir siteyi eklemek

`C:\Program Files\dpi-bypass\hostlist.txt` dosyasını yönetici olarak açın ve her satıra bir alan adı yazın. Alt alan adları da kapsanır. Sonra hizmeti yeniden başlatın:

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
| `config.json` | DNS sunucuları, kontrol adresleri, süreler. |
| `hostlist.txt` | DPI aşmanın uygulandığı alan adları. |
| `bin\` | zapret `winws` ve WinDivert. Bkz. [THIRD-PARTY.md](THIRD-PARTY.md). |
| `tools\fetch-zapret.ps1` | zapret dosyalarını sabit bir commit'ten indirir ve hash'lerini doğrular. |

## Güvenlik notu

`winws.exe` imzasızdır. `WinDivert64.sys` imzalı bir çekirdek sürücüsüdür ve ağ paketlerini yakalayabilir. Bu yüzden antivirüsler bunları "HackTool" olarak işaretleyebilir. Dosyaların SHA256 değerleri `lib.ps1` içinde tutulur. Kurulum, kopyalamadan önce ve sonra bu değerleri kontrol eder.
