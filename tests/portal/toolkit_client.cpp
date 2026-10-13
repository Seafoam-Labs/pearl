// A real Qt native-dialog caller using Qt's xdgdesktopportal platform theme.
#include <QApplication>
#include <QFileDialog>
#include <QUrl>
#include <QTimer>
#include <cstdio>
int main(int argc, char **argv) {
    QApplication app(argc, argv);
    if (argc != 2) return 2;
    QWidget parent;
    parent.setWindowTitle("Qt portal consumer");
    parent.show();
    // Qt discovers the portal version asynchronously during startup. A user
    // opens a dialog after the event loop starts, not in QApplication's ctor.
    QTimer::singleShot(300, [&] {
        QString file = QFileDialog::getOpenFileName(&parent, "Qt portal test", argv[1]);
        if (file.isEmpty()) { app.exit(1); return; }
        std::printf("SELECTED %s\n", QUrl::fromLocalFile(file).toEncoded().constData());
        app.exit(0);
    });
    return app.exec();
}
