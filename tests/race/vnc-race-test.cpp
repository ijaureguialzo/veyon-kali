// vnc-race-test — synthetic A/B test for the VncConnection decode/paint
// race (upstream 20f0b6298 "present framebuffer updates only once
// complete", backported as patches/0023).
//
// It connects a VncConnection to the synthetic RFB server
// (rfb-race-server.py), which pushes a full-frame raw update every 20 ms
// (a 40 px bar moving 30 px per frame). A GUI-thread timer then reads the
// connection's image the way VncViewWidget::paintEvent() would: fetch the
// image, then walk its rows in paced chunks so that one read spans several
// decoder updates.
//
// For every capture it checks whether the bar's left edge is consistent
// across all rows. In a consistent frame every row shows the same edge; a
// torn framebuffer (the decoder writing the live buffer while we read it)
// shows rows from two different server frames, i.e. edges that differ by
// more than the bar movement per frame.
//
// RACE_MODE=0: presentCompleteUpdates=false -> image() is the live decode
//             buffer (the historical, racy behaviour). Expect torn > 0.
// RACE_MODE=1: presentCompleteUpdates=true  -> image() is a double
//             buffer, copied under a write lock on update completion
//             (the fix). Expect torn == 0.
//
// Env vars: RACE_HOST (127.0.0.1), RACE_PORT (12345), RACE_MODE (0),
//           RACE_SECONDS (30), RACE_RESULT (/tmp/race_result.txt)
// Run with: QT_QPA_PLATFORM=offscreen and DYLD_LIBRARY_PATH pointing at
//           the veyon stage Resources/lib (veyon-core) + PlugIns.
//
// Build (from build/stage/bin of the veyon-macos tree):
//   clang++ -std=c++17 -fPIC \
//     -I<veyon-macos>/core/src -I<veyon-macos>/build/core/src \
//     -I<qtbase>/include -I<qtbase>/include/QtCore -I<qtbase>/include/QtGui \
//     -I<qtbase>/include/QtNetwork -I<qtbase>/include/QtWidgets \
//     -F<qtbase>/lib -F<qca>/lib -F<qt5compat>/lib \
//     -framework QtCore -framework QtGui -framework QtNetwork \
//     -framework QtWidgets -framework QtConcurrent \
//     -L../Resources/lib -lveyon-core -Wl,-rpath,../Resources/lib \
//     vnc-race-test.cpp -o vnc-race-test
//
// Verified results (macOS, veyon 4.11.2 + patches/0023, libvncclient
// 0.9.15, 800x600 @ 50 fps full-frame raw updates, 30 s runs):
//   RACE_MODE=0: 9/292 and 13/438 torn captures  (~3%)
//   RACE_MODE=1: 0/292 and 0/438 torn captures   (0%)

#include <QCoreApplication>
#include <QGuiApplication>
#include <QImage>
#include <QTimer>
#include <QFile>
#include <QThread>
#include <QElapsedTimer>

#include <cstdio>

#include "VeyonCore.h"
#include "VncConnection.h"

static long g_total = 0;
static long g_torn = 0;
static int  g_fail = 0;

int main( int argc, char** argv )
{
	qputenv( "QT_QPA_PLATFORM", "offscreen" );
	qInstallMessageHandler( []( QtMsgType, const QMessageLogContext& ctx, const QString& msg ) {
		Q_UNUSED( ctx );
		fprintf( stderr, "%s\n", msg.toUtf8().constData() );
	} );

	VeyonCore::setupApplicationParameters();
	QGuiApplication app( argc, argv );

	VeyonCore core( &app, VeyonCore::Component::Master, QStringLiteral( "race-test" ) );

	auto* connection = new VncConnection( &core );
	connection->setHost( qEnvironmentVariable( "RACE_HOST", "127.0.0.1" ) );
	connection->setPort( qEnvironmentVariable( "RACE_PORT", "12345" ).toInt() );
	const bool mode = qEnvironmentVariable( "RACE_MODE", "0" ).toInt() == 1;
	connection->setPresentCompleteUpdates( mode );
	connection->setFramebufferUpdateInterval( 33 );
	connection->start();

	const int runSeconds = qEnvironmentVariable( "RACE_SECONDS", "30" ).toInt();

	// report the imageUpdated() emission rate (decoder activity)
	int updatesInWindow = 0;
	QTimer updReport;
	updReport.setInterval( 1000 );
	QObject::connect( connection, &VncConnection::imageUpdated,
					  [&]( int, int, int, int ) { updatesInWindow++; } );
	QObject::connect( &updReport, &QTimer::timeout, [&]() {
		qInfo() << "imageUpdated/s:" << updatesInWindow;
		updatesInWindow = 0;
	} );
	updReport.start();

	QElapsedTimer runTimer;
	runTimer.start();

	QTimer reader;
	reader.setInterval( 16 );
	QObject::connect( &reader, &QTimer::timeout, [&]() {
		if (connection->state() != VncConnection::State::Connected)
		{
			return;
		}

		const QImage image = connection->image();
		if (image.isNull() || image.size() != QSize( 800, 600 ))
		{
			return;
		}

		// Emulate a slow paint (like a Retina 2x upscale): walk the rows in
		// chunks with small sleeps in between so that the read spans several
		// decoder updates. In a racy (live-buffer) mode the decoder keeps
		// writing into this same memory while we read it.
		const int chunk = 32;
		for (int y = 0; y < image.height(); y += chunk)
		{
			QThread::msleep( 2 );
			const auto* l = image.constScanLine( y );
			Q_UNUSED( l );
		}

		// Check consistency of the live image: the bar is 40 px wide and
		// moves 30 px per server frame. In a consistent frame every row has
		// its left bar edge at the same x; a torn framebuffer shows rows
		// from two different frames, i.e. edges differing by ~30 px.
		g_total++;
		int minX = 1 << 30;
		int maxX = -1;
		for (int y = 0; y < image.height(); y += 4)
		{
			// pace the analysis a little so it too spans decoder updates
			if ( ( y / 4 ) % 8 == 0 )
			{
				QThread::msleep( 1 );
			}
			const auto* line = reinterpret_cast<const QRgb*>( image.constScanLine( y ) );
			int x = -1;
			for (int xi = 0; xi < image.width(); ++xi)
			{
				const int lum = ( qRed( line[xi] ) + qGreen( line[xi] ) + qBlue( line[xi] ) ) / 3;
				if (lum > 0xC0)
				{
					x = xi;
					break;
				}
			}
			if (x > 0 && (x < minX || maxX < 0))
			{
				minX = qMin( minX, x );
				maxX = qMax( maxX, x );
			}
		}

		if (maxX > 0 && (maxX - minX) > 20)
		{
			g_torn++;
			qInfo() << "TORN" << g_torn << "bar edge range" << minX << ".." << maxX;
		}

		if (g_total % 50 == 0)
		{
			qInfo() << "captures:" << g_total << "torn:" << g_torn;
		}

		if (runTimer.elapsed() >= runSeconds * 1000)
		{
			reader.stop();
			updReport.stop();
			connection->stop();
			qInfo() << "mode(presentCompleteUpdates):" << mode;
			qInfo() << "SUMMARY captures=" << g_total << "torn=" << g_torn;
			g_fail = (g_torn > 0) ? 1 : 0;
			QCoreApplication::exit( g_fail );
		}
	} );
	reader.start();

	app.exec();

	connection->stopAndDeleteLater();

	QFile result( qEnvironmentVariable( "RACE_RESULT", "/tmp/race_result.txt" ) );
	if (result.open( QFile::WriteOnly | QFile::Truncate ))
	{
		result.write( ( "captures=" + QString::number( g_total ) +
						" torn=" + QString::number( g_torn ) + "\n" ).toUtf8().constData() );
	}
	return g_fail;
}
