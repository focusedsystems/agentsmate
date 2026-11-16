extension LaneIconLibrary {
    /// SF Symbols offered by the picker, all available on macOS 14.
    public static let symbolNames: [String] = """
    terminal terminal.fill apple.terminal chevron.left.forwardslash.chevron.right curlybraces command \
    hammer hammer.fill wrench.and.screwdriver wrench.adjustable gearshape gearshape.2 slider.horizontal.3 \
    ladybug ant cpu memorychip externaldrive internaldrive opticaldiscdrive server.rack network \
    antenna.radiowaves.left.and.right wifi bolt bolt.fill bolt.horizontal flame flame.fill drop drop.fill \
    leaf leaf.fill tree ladybug.fill sparkles sparkle wand.and.stars wand.and.rays star star.fill \
    moon moon.fill moon.stars sun.max sun.max.fill sunrise sunset cloud cloud.fill cloud.rain cloud.bolt \
    snowflake wind tornado umbrella thermometer.medium rainbow \
    folder folder.fill tray tray.full archivebox doc doc.text doc.richtext book book.fill books.vertical \
    bookmark bookmark.fill newspaper note.text list.bullet checklist text.alignleft \
    pencil pencil.tip paintbrush paintbrush.fill paintpalette scribble highlighter eraser scissors \
    ruler level paperclip link globe globe.americas map mappin mappin.and.ellipse location compass.drawing \
    house house.fill building building.2 building.columns storefront cart bag creditcard banknote \
    chart.bar chart.line.uptrend.xyaxis chart.pie chart.xyaxis.line gauge.medium speedometer timer stopwatch \
    clock alarm calendar hourglass \
    person person.fill person.2 person.3 person.crop.circle person.badge.plus figure.walk figure.run \
    figure.hiking figure.yoga figure.climbing hand.raised hand.thumbsup hand.wave \
    face.smiling heart heart.fill brain brain.head.profile eye eye.fill nose \
    bubble.left bubble.left.and.bubble.right text.bubble quote.bubble envelope envelope.fill paperplane \
    paperplane.fill phone bell bell.fill megaphone speaker.wave.2 mic music.note music.quarternote.3 \
    guitars pianokeys headphones radio tv film video camera photo theatermasks gamecontroller \
    dice puzzlepiece flag flag.fill flag.checkered trophy medal rosette crown gift balloon party.popper \
    cube cube.fill shippingbox shippingbox.fill cube.transparent square.stack.3d.up circle.hexagongrid \
    hexagon hexagon.fill octagon pentagon triangle diamond diamond.fill seal shield shield.fill lock lock.fill \
    key key.fill lock.open touchid faceid \
    airplane car car.fill bus tram bicycle ferry sailboat fuelpump \
    mountain.2 tent tree.fill pawprint pawprint.fill hare tortoise bird fish lizard \
    cat dog carrot fork.knife cup.and.saucer wineglass birthday.cake \
    mug popcorn pills cross.case stethoscope syringe bandage \
    lightbulb lightbulb.fill lamp.desk flashlight.on.fill fanblades powerplug battery.100 \
    atom flask testtube.2 binoculars scope magnifyingglass \
    graduationcap backpack pencil.and.ruler briefcase suitcase \
    laptopcomputer desktopcomputer macmini display keyboard computermouse printer \
    iphone ipad applewatch airpods homepod headphones.circle \
    circle circle.fill square square.fill triangle.fill capsule capsule.fill \
    checkmark.circle checkmark.seal xmark.circle exclamationmark.triangle questionmark.circle info.circle \
    plus.circle minus.circle arrow.triangle.branch arrow.triangle.merge arrow.triangle.pull \
    arrow.triangle.2.circlepath arrow.clockwise arrow.up.circle arrow.down.circle infinity \
    tag tag.fill ticket scroll hourglass.bottomhalf.filled \
    waveform waveform.path.ecg figure.wave bolt.circle bolt.shield \
    sportscourt football basketball tennisball volleyball baseball soccerball \
    skateboard surfboard dumbbell trophy.fill target scope
    """
        .split(whereSeparator: { $0 == " " || $0 == "\n" })
        .map(String.init)
        .reduce(into: [String]()) { out, name in if !out.contains(name) { out.append(name) } }
}
