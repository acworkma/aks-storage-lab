package com.azure.aksstorage

import akka.actor.typed.ActorSystem
import akka.actor.typed.scaladsl.Behaviors
import akka.http.scaladsl.Http
import akka.http.scaladsl.model._
import akka.http.scaladsl.server.Directives._
import akka.http.scaladsl.marshallers.sprayjson.SprayJsonSupport._
import spray.json.DefaultJsonProtocol._
import spray.json._
import com.azure.identity.DefaultAzureCredentialBuilder
import com.azure.storage.blob.{BlobServiceClient, BlobServiceClientBuilder, BlobContainerClient}
import com.typesafe.scalalogging.LazyLogging
import scala.concurrent.{ExecutionContextExecutor, Future}
import scala.jdk.CollectionConverters._
import scala.util.{Try, Success, Failure}
import java.time.OffsetDateTime
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets

object Main extends App with LazyLogging {
  
  // JSON protocols for response models
  case class HealthResponse(status: String, storage_account: String, container: String, authentication: String, timestamp: String)
  case class BlobInfo(name: String, size: Long, last_modified: Option[String], content_type: Option[String])
  case class ListResponse(container: String, blob_count: Int, blobs: List[BlobInfo], timestamp: String)
  case class UploadResponse(status: String, blob_name: String, container: String, size: Int, message: String, timestamp: String)
  case class ErrorResponse(status: String, error: String, timestamp: String)
  case class HomeResponse(message: String, storage_account: String, container: String)
  
  implicit val healthResponseFormat: RootJsonFormat[HealthResponse] = jsonFormat5(HealthResponse.apply)
  implicit val blobInfoFormat: RootJsonFormat[BlobInfo] = jsonFormat4(BlobInfo.apply)
  implicit val listResponseFormat: RootJsonFormat[ListResponse] = jsonFormat4(ListResponse.apply)
  implicit val uploadResponseFormat: RootJsonFormat[UploadResponse] = jsonFormat6(UploadResponse.apply)
  implicit val errorResponseFormat: RootJsonFormat[ErrorResponse] = jsonFormat3(ErrorResponse.apply)
  implicit val homeResponseFormat: RootJsonFormat[HomeResponse] = jsonFormat3(HomeResponse.apply)
  
  // Configuration from environment variables
  val storageAccountName = sys.env.getOrElse("AZURE_STORAGE_ACCOUNT_NAME", 
    throw new RuntimeException("AZURE_STORAGE_ACCOUNT_NAME environment variable is not set"))
  val containerName = sys.env.getOrElse("AZURE_STORAGE_CONTAINER_NAME", "data")
  
  logger.info(s"Initializing AKS Storage Lab application")
  logger.info(s"Storage Account: $storageAccountName")
  logger.info(s"Container: $containerName")
  
  // Initialize Azure Storage client with DefaultAzureCredential (workload identity)
  val accountUrl = s"https://$storageAccountName.blob.core.windows.net"
  val credential = new DefaultAzureCredentialBuilder().build()
  val blobServiceClient: BlobServiceClient = new BlobServiceClientBuilder()
    .endpoint(accountUrl)
    .credential(credential)
    .buildClient()
  
  logger.info(s"BlobServiceClient initialized for $accountUrl")
  
  // Akka HTTP setup
  implicit val system: ActorSystem[Nothing] = ActorSystem(Behaviors.empty, "aks-storage-app")
  implicit val executionContext: ExecutionContextExecutor = system.executionContext
  
  // Helper to get current timestamp
  def currentTimestamp: String = OffsetDateTime.now().toString
  
  // Routes
  val route =
    pathEndOrSingleSlash {
      get {
        complete(HomeResponse(
          message = "AKS Storage Lab - Scala Edition",
          storage_account = storageAccountName,
          container = containerName
        ))
      }
    } ~
    path("health") {
      get {
        val response = Try {
          val containerClient = blobServiceClient.getBlobContainerClient(containerName)
          containerClient.getProperties() // Verify connectivity
          HealthResponse(
            status = "healthy",
            storage_account = storageAccountName,
            container = containerName,
            authentication = "workload_identity",
            timestamp = currentTimestamp
          )
        }.recover {
          case ex: Exception =>
            logger.error(s"Health check failed: ${ex.getMessage}")
            ErrorResponse(
              status = "unhealthy",
              error = "Unable to connect to storage account. Check logs for details.",
              timestamp = currentTimestamp
            )
        }.get
        
        response match {
          case h: HealthResponse => complete(h)
          case e: ErrorResponse => complete(StatusCodes.InternalServerError -> e)
        }
      }
    } ~
    path("list") {
      get {
        val response = Try {
          val containerClient = blobServiceClient.getBlobContainerClient(containerName)
          val blobs = containerClient.listBlobs().asScala.map { blobItem =>
            BlobInfo(
              name = blobItem.getName,
              size = blobItem.getProperties.getContentLength,
              last_modified = Option(blobItem.getProperties.getLastModified).map(_.toString),
              content_type = Option(blobItem.getProperties.getContentType)
            )
          }.toList
          
          logger.info(s"Listed ${blobs.size} blobs from container $containerName")
          
          ListResponse(
            container = containerName,
            blob_count = blobs.size,
            blobs = blobs,
            timestamp = currentTimestamp
          )
        }.recover {
          case ex: Exception =>
            logger.error(s"Failed to list blobs: ${ex.getMessage}")
            ErrorResponse(
              status = "error",
              error = "Unable to list blobs. Check logs for details.",
              timestamp = currentTimestamp
            )
        }.get
        
        response match {
          case l: ListResponse => complete(l)
          case e: ErrorResponse => complete(StatusCodes.InternalServerError -> e)
        }
      }
    } ~
    path("upload") {
      post {
        val response = Try {
          val timestamp = currentTimestamp
          val blobName = s"test-file-scala-$timestamp.txt"
          val content = s"Test file created at $timestamp\nThis file was uploaded from Scala using workload identity!\n"
          val bytes = content.getBytes(StandardCharsets.UTF_8)
          
          val blobClient = blobServiceClient.getBlobContainerClient(containerName).getBlobClient(blobName)
          val inputStream = new ByteArrayInputStream(bytes)
          blobClient.upload(inputStream, bytes.length, true)
          
          logger.info(s"Successfully uploaded blob: $blobName")
          
          UploadResponse(
            status = "success",
            blob_name = blobName,
            container = containerName,
            size = bytes.length,
            message = "File uploaded successfully using managed identity",
            timestamp = timestamp
          )
        }.recover {
          case ex: Exception =>
            logger.error(s"Failed to upload blob: ${ex.getMessage}")
            ErrorResponse(
              status = "error",
              error = "Unable to upload file. Check logs for details.",
              timestamp = currentTimestamp
            )
        }.get
        
        response match {
          case u: UploadResponse => complete(u)
          case e: ErrorResponse => complete(StatusCodes.InternalServerError -> e)
        }
      }
    }
  
  // Start HTTP server
  val bindingFuture = Http().newServerAt("0.0.0.0", 8080).bind(route)
  
  bindingFuture.onComplete {
    case Success(binding) =>
      val address = binding.localAddress
      logger.info(s"AKS Storage Lab server online at http://${address.getHostString}:${address.getPort}/")
    case Failure(ex) =>
      logger.error(s"Failed to bind HTTP endpoint, terminating system: ${ex.getMessage}")
      system.terminate()
  }
}
