// Qt Quick/Kirigami palette consumer; does not pretend Darkly is a QML style.
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QTimer>
#include <QColor>
#include <QJsonDocument>
#include <QJsonObject>
#include <cstdio>
int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    QQmlApplicationEngine engine;
    const bool kirigami = app.arguments().contains("--kirigami");
    QByteArray qml = "import QtQuick\nimport QtQuick.Controls\n";
    if (kirigami) qml += "import org.kde.kirigami as Kirigami\n";
    qml += "ApplicationWindow { width: 360; height: 200; visible: true; property color pearlWindow: palette.window; property color pearlText: palette.windowText; property color pearlHighlight: palette.highlight; ";
    qml += kirigami ? "Kirigami.Heading { text: 'Pearl Kirigami palette' }" : "Button { text: 'Pearl Qt Quick palette' }";
    qml += "}";
    engine.loadData(qml);
    if (engine.rootObjects().isEmpty()) return 2;
    QTimer::singleShot(200, [&] {
        auto root = engine.rootObjects().first();
        QJsonObject report;
        report["qt"] = qVersion(); report["style"] = QQuickStyle::name(); report["kirigami"] = kirigami;
        for (auto name : {"pearlWindow", "pearlText", "pearlHighlight"}) report[name] = root->property(name).value<QColor>().name();
        auto bytes = QJsonDocument(report).toJson(QJsonDocument::Compact);
        std::fwrite(bytes.constData(), 1, bytes.size(), stdout); app.quit();
    });
    return app.exec();
}
