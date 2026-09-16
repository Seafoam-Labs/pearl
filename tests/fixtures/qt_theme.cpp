// Real Qt consumer for palette, font, style and geometry acceptance.
#include <QApplication>
#include <QStyle>
#include <QProxyStyle>
#include <QStyleFactory>
#include <QPalette>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPushButton>
#include <QLineEdit>
#include <QCheckBox>
#include <QComboBox>
#include <QProgressBar>
#include <QVBoxLayout>
#include <QLabel>
#include <QTimer>
#include <QFile>
#include <QTextStream>

static QJsonObject report(QWidget &window) {
    QJsonObject result;
    result["qt"] = qVersion();
    result["style"] = qApp->style()->objectName();
    auto base = qApp->style();
    for (int i = 0; i < 8; ++i) { auto proxy = qobject_cast<QProxyStyle *>(base); if (!proxy || proxy->baseStyle() == base) break; base = proxy->baseStyle(); }
    result["base_style"] = base->objectName();
    result["base_class"] = base->metaObject()->className();
    result["style_class"] = qApp->style()->metaObject()->className();
    result["styles"] = QJsonArray::fromStringList(QStyleFactory::keys());
    result["font"] = qApp->font().toString();
    result["point_size"] = qApp->font().pointSizeF();
    result["pixel_size"] = qApp->font().pixelSize();
    result["icon_theme"] = QIcon::themeName();
    QJsonObject groups;
    for (auto group : {QPalette::Active, QPalette::Inactive, QPalette::Disabled}) {
        QJsonArray roles;
        for (int i = 0; i < QPalette::NColorRoles; ++i)
            roles.append(window.palette().color(group, QPalette::ColorRole(i)).name(QColor::HexArgb));
        groups[QString::number(group)] = roles;
    }
    result["palette"] = groups;
    result["button_height"] = window.findChild<QPushButton *>()->sizeHint().height();
    return result;
}
int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QWidget window;
    window.setWindowTitle("Pearl · Darkly preview");
    auto layout = new QVBoxLayout(&window);
    layout->addWidget(new QLabel("Qt application appearance"));
    layout->addWidget(new QPushButton("Enabled button"));
    auto disabled = new QPushButton("Disabled button"); disabled->setEnabled(false);
    layout->addWidget(disabled);
    auto edit = new QLineEdit; edit->setPlaceholderText("Placeholder text"); layout->addWidget(edit);
    layout->addWidget(new QCheckBox("Check box"));
    auto combo = new QComboBox; combo->addItems({"First choice", "Second choice"}); layout->addWidget(combo);
    auto progress = new QProgressBar; progress->setValue(65); layout->addWidget(progress);
    window.resize(400, 360); window.show();
    const auto args = app.arguments();
    const auto output = qEnvironmentVariable("PEARL_QT_REPORT");
    QTimer timer;
    QObject::connect(&timer, &QTimer::timeout, [&] {
        const auto bytes = QJsonDocument(report(window)).toJson();
        const auto screenshot = qEnvironmentVariable("PEARL_QT_SCREENSHOT");
        if (!screenshot.isEmpty()) window.grab().save(screenshot);
        if (!output.isEmpty()) { QFile file(output); if (file.open(QIODevice::WriteOnly)) file.write(bytes); }
        else { QTextStream(stdout) << bytes; }
        if (!args.contains("--watch")) app.quit();
    });
    timer.start(args.contains("--watch") ? 200 : 100);
    return app.exec();
}
