// Optional process boundary: loading a broken third-party style cannot crash Pearl.
#include <QApplication>
#include <QStyleFactory>
#include <QStyle>
#include <QLibraryInfo>
#include <QPluginLoader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QIcon>
#include <QFont>
#include <QFile>
#include <QFileInfo>
#include <cstdio>
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
static_assert(QT_VERSION >= QT_VERSION_CHECK(6, 6, 0), "Pearl's Qt 6 palette adapter requires Qt 6.6 or newer");
#endif
int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    qunsetenv("QT_QPA_PLATFORMTHEME");
    qputenv("QT_STYLE_OVERRIDE", "Fusion");
    QApplication app(argc, argv);
    QJsonObject result;
    result["version"] = 2;
    result["qt"] = qVersion();
    QStyle *style = QStyleFactory::create("Darkly");
    result["darkly"] = style != nullptr;
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    QString plugins = QLibraryInfo::path(QLibraryInfo::PluginsPath);
    QString name = "qt6engine";
#else
    QString plugins = QLibraryInfo::location(QLibraryInfo::PluginsPath);
    QString name = "qt5engine";
#endif
    auto findPlugin = [&](const QString &suffix) {
        for (const auto &directory : QCoreApplication::libraryPaths()) {
            const QString file = directory + suffix;
            if (QFileInfo::exists(file)) return file;
        }
        return plugins + suffix;
    };
    QPluginLoader loader(findPlugin("/platformthemes/lib" + name + "-plugin.so"));
    QPluginLoader engineStyle(findPlugin("/styles/lib" + name + "-style.so"));
    result["engine"] = loader.load();
    result["engine_style"] = engineStyle.load();
    result["alias"] = loader.metaData()["MetaData"].toObject()["Keys"].toArray().contains("qtengine");
    result["family"] = app.font().family();
    result["font"] = app.font().toString();
    result["icon_theme"] = QIcon::themeName();
    if (argc >= 3) {
        QFont font = app.font();
        if (argc >= 4) {
            QFile existing(QString::fromUtf8(argv[3]));
            if (existing.open(QIODevice::ReadOnly)) {
                auto root = QJsonDocument::fromJson(existing.read(65537)).object();
                const QString previous = root["theme"].toObject()["font"].toObject()["family"].toString();
                if (!previous.isEmpty()) font.setFamily(previous);
            }
        }
        if (*argv[1]) font.setFamily(QString::fromUtf8(argv[1]));
        font.setPixelSize(QString::fromLatin1(argv[2]).toInt());
        result["font"] = font.toString();
    }
    bool iconAvailable = argc < 5 || !*argv[4];
    if (!iconAvailable) for (const auto &path : QIcon::themeSearchPaths())
        if (QFileInfo::exists(path + "/" + QString::fromUtf8(argv[4]) + "/index.theme")) iconAvailable = true;
    result["icon_available"] = iconAvailable;
    auto bytes = QJsonDocument(result).toJson(QJsonDocument::Compact);
    std::fwrite(bytes.constData(), 1, bytes.size(), stdout);
    delete style;
    return 0;
}
