name := "aks-storage-app"

version := "1.0.0"

scalaVersion := "3.3.1"

// Assembly plugin for fat JAR
assembly / assemblyJarName := "aks-storage-app.jar"
assembly / mainClass := Some("com.azure.aksstorage.Main")

// Merge strategy for assembly conflicts
assembly / assemblyMergeStrategy := {
  case PathList("META-INF", "MANIFEST.MF") => MergeStrategy.discard
  case PathList("META-INF", "services", _*) => MergeStrategy.concat
  case PathList("META-INF", _*) => MergeStrategy.discard
  case PathList("reference.conf") => MergeStrategy.concat
  case _ => MergeStrategy.first
}

libraryDependencies ++= Seq(
  // Akka HTTP for web server
  "com.typesafe.akka" %% "akka-http" % "10.5.3",
  "com.typesafe.akka" %% "akka-stream" % "2.8.5",
  "com.typesafe.akka" %% "akka-actor-typed" % "2.8.5",
  
  // JSON support
  "com.typesafe.akka" %% "akka-http-spray-json" % "10.5.3",
  
  // Azure SDK (Java libraries work directly with Scala)
  "com.azure" % "azure-storage-blob" % "12.25.1",
  "com.azure" % "azure-identity" % "1.11.2",
  
  // Logging
  "ch.qos.logback" % "logback-classic" % "1.4.14",
  "com.typesafe.scala-logging" %% "scala-logging" % "3.9.5"
)

// Scala 3 compiler options
scalacOptions ++= Seq(
  "-encoding", "UTF-8",
  "-deprecation",
  "-feature",
  "-unchecked"
)
