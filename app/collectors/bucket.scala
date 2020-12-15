package collectors

import java.time.Instant

import agent._
import conf.AWS
import controllers.routes
import play.api.mvc.Call
import software.amazon.awssdk.regions.Region
import software.amazon.awssdk.services.s3.S3Client
import software.amazon.awssdk.services.s3.model.{GetBucketLocationRequest, ListBucketsRequest, S3Exception, Bucket => AWSBucket}
import utils.Logging

import scala.jdk.CollectionConverters._
import scala.language.{postfixOps, reflectiveCalls}
import scala.util.Try
import scala.util.control.NonFatal


class BucketCollectorSet(accounts: Accounts) extends CollectorSet[Bucket](ResourceType("bucket"), accounts, Some(Global)) {
  val lookupCollector: PartialFunction[Origin, Collector[Bucket]] = {
    case amazon: AmazonOrigin => AWSBucketCollector(amazon, resource, amazon.crawlRate(resource.name))
  }
}

case class AWSBucketCollector(origin: AmazonOrigin, resource: ResourceType, crawlRate: CrawlRate) extends Collector[Bucket] with Logging {

  val client = S3Client
    .builder
    .credentialsProvider(origin.credentials.provider)
    .region(origin.awsRegionV2)
    .overrideConfiguration(AWS.clientConfig)
    .build

  def crawl: Iterable[Bucket] = {
    val request = ListBucketsRequest.builder.build
    client.listBuckets(request).buckets().asScala
      .flatMap {
        Bucket.fromApiData(_, client)
      }
  }
}

object Bucket {

  private def arn(bucketName: String) = s"arn:aws:s3:::$bucketName" 

  def fromApiData(bucket: AWSBucket, client: S3Client): Option[Bucket] = {
    val bucketName = bucket.name
    try {
      val bucketRegion = Option(client.getBucketLocation(GetBucketLocationRequest.builder.bucket(bucketName).build).locationConstraintAsString)
      Some(Bucket(
        arn = arn(bucketName),
        name = bucketName,
        region = bucketRegion.getOrElse(Region.US_EAST_1.id),
        createdTime = Try(bucket.creationDate).toOption
      ))
    } catch {
      case e:S3Exception if e.awsErrorDetails.errorCode == "NoSuchBucket" => None
      case e:S3Exception if e.awsErrorDetails.errorCode == "AuthorizationHeaderMalformed" => None
      case NonFatal(t) =>
        throw new IllegalStateException(s"Failed when building info for bucket $bucketName", t)
    }
  }
}

case class Bucket(
  arn: String,
  name: String,
  region: String,
  createdTime: Option[Instant]
) extends IndexedItem {
  override def callFromArn: (String) => Call = arn => routes.Api.bucket(arn)
}